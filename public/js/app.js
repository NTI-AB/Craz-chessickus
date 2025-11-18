document.addEventListener('DOMContentLoaded', () => {
  console.log('Chess JS loaded');
  
  const boardWrapper = document.querySelector('.board-wrapper');
  if (!boardWrapper) {
    console.error('No board wrapper found');
    return;
  }
  
  const board = document.querySelector('table.board');
  if (!board) {
    console.error('No board found');
    return;
  }

  const normalizeColor = value => (value || '').toString().trim().toLowerCase();
  const body = document.body;
  const bodyColor = body?.classList.contains('black')
    ? 'black'
    : body?.classList.contains('white')
      ? 'white'
      : '';
  const playerFromPath = window.location.pathname.includes('/black')
    ? 'black'
    : window.location.pathname.includes('/white')
      ? 'white'
      : '';
  
  let currentTurn = normalizeColor(boardWrapper.getAttribute('data-turn')) || 'white';
  const playerAttr = boardWrapper.getAttribute('data-player');
  const playerColor = normalizeColor(playerAttr) || bodyColor || playerFromPath || 'white';
  const orientation = boardWrapper.getAttribute('data-orientation') || 'white';
  const currentTurnEl = document.querySelector('.current-turn-value');
  const waitingNotice = document.querySelector('.waiting-notice');
  console.log('Current turn:', currentTurn);
  console.log('Viewing as:', playerColor, 'orientation:', orientation);

  let selected = null;
  let validMoves = [];

  const capitalize = str => {
    if (!str) return '';
    return str.charAt(0).toUpperCase() + str.slice(1);
  };

  function updateTurnUI() {
    if (currentTurnEl) {
      currentTurnEl.textContent = capitalize(currentTurn);
    }
    if (waitingNotice) {
      const shouldWait = playerColor !== currentTurn;
      waitingNotice.textContent = `Waiting for ${capitalize(currentTurn)} to move.`;
      waitingNotice.classList.toggle('hidden', !shouldWait);
    }
  }

  updateTurnUI();

  function clearHighlights() {
    board.querySelectorAll('td.selected').forEach(el => el.classList.remove('selected'));
    board.querySelectorAll('td.valid-move').forEach(el => el.classList.remove('valid-move'));
  }

  function tdAt(x, y) {
    return board.querySelector(`td[data-x="${x}"][data-y="${y}"]`);
  }

  function hasPiece(td) {
    return !!td.querySelector('img.piece');
  }

  function pieceColor(td) {
    const img = td.querySelector('img.piece');
    if (!img) return null;
    const alt = img.getAttribute('alt') || '';
    const color = alt.split(' ')[0] || null;
    return color;
  }

  async function fetchValidMoves(x, y) {
    try {
      const res = await fetch(`/valid_moves?x=${x}&y=${y}`);
      if (!res.ok) return [];
      const data = await res.json();
      return (data.moves || []).map(([mx, my]) => ({ x: mx, y: my }));
    } catch (error) {
      console.error('Error fetching valid moves:', error);
      return [];
    }
  }

  async function onSquareClick(e) {
    console.log('Click detected on:', e.target);
    
    // Get the TD element
    let td = e.target;
    if (td.tagName === 'IMG') {
      td = td.parentElement;
    }
    if (td.tagName !== 'TD') {
      console.log('Not a TD, ignoring');
      return;
    }
    
    const x = parseInt(td.getAttribute('data-x'), 10);
    const y = parseInt(td.getAttribute('data-y'), 10);
    
    console.log(`Clicked square: (${x}, ${y})`);
    
    if (isNaN(x) || isNaN(y)) {
      console.error('Invalid coordinates');
      return;
    }

    const isPlayersTurn = playerColor === currentTurn;

    // If clicking a valid move destination -> submit move
    if (td.classList.contains('valid-move') && selected) {
      console.log(`Moving from (${selected.x}, ${selected.y}) to (${x}, ${y})`);
      const from = `${selected.x},${selected.y}`;
      const to = `${x},${y}`;
      
      try {
        await fetch('/move', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ from, to, player: playerColor }).toString(),
        });
        window.location.reload();
      } catch (error) {
        console.error('Error making move:', error);
      }
      return;
    }

    if (!isPlayersTurn) {
      console.log('Not this player turn, ignoring selection');
      clearHighlights();
      selected = null;
      validMoves = [];
      return;
    }

    const clickedPieceColor = pieceColor(td);
    console.log('Piece color at square:', clickedPieceColor);
    
    // Clicking on a piece of the current turn -> select it
    if (hasPiece(td) && clickedPieceColor === playerColor) {
      console.log('Selecting piece');
      
      // If clicking the same piece, deselect it
      if (selected && selected.x === x && selected.y === y) {
        console.log('Deselecting');
        clearHighlights();
        selected = null;
        validMoves = [];
        return;
      }

      clearHighlights();
      td.classList.add('selected');
      selected = { x, y };
      
      console.log('Fetching valid moves...');
      validMoves = await fetchValidMoves(x, y);
      console.log('Valid moves:', validMoves);
      
      validMoves.forEach(m => {
        const dest = tdAt(m.x, m.y);
        if (dest) dest.classList.add('valid-move');
      });
    } else {
      console.log('Clearing selection');
      clearHighlights();
      selected = null;
      validMoves = [];
    }
  }

  async function refreshGameState() {
    try {
      const res = await fetch('/state');
      if (!res.ok) return;
      const data = await res.json();
      const nextTurn = normalizeColor(data.turn);
      if (nextTurn && nextTurn !== currentTurn) {
        currentTurn = nextTurn;
        boardWrapper.setAttribute('data-turn', currentTurn);
        console.log('Turn updated to:', currentTurn);
        updateTurnUI();
        updateSelectableSquares();
      }
    } catch (error) {
      console.error('Error refreshing state:', error);
    }
  }

  // Mark selectable squares
  function updateSelectableSquares() {
    const canMoveNow = playerColor === currentTurn;
    board.querySelectorAll('td').forEach(td => {
      td.classList.remove('can-select');
      if (canMoveNow && hasPiece(td) && pieceColor(td) === playerColor) {
        td.classList.add('can-select');
      }
    });
  }

  updateSelectableSquares();
  refreshGameState();
  setInterval(refreshGameState, 3000);

  let sseReloading = false;
  function forceReload() {
    if (sseReloading) return;
    sseReloading = true;
    const url = new URL(window.location.href);
    url.searchParams.set('_', Date.now()); // cache-buster
    window.location.replace(url.toString());
  }

  // Listen for server-sent events to refresh when any move/reset happens
  function setupSSE() {
    if (!window.EventSource) {
      console.warn('EventSource not supported, falling back to polling only');
      return;
    }
    const es = new EventSource('/events');
    es.addEventListener('refresh', (event) => {
      try {
        const payload = JSON.parse(event.data || '{}');
        console.log('Refresh event received', payload);
      } catch (err) {
        console.log('Refresh event received');
      }
      forceReload();
    });
    es.addEventListener('ping', () => {
      // Keep-alive / connection confirmation
    });
    es.onerror = () => {
      console.warn('SSE connection lost, retrying automatically...');
    };
  }

  setupSSE();
  
  // Add click listener to the entire board
  board.addEventListener('click', onSquareClick);
  console.log('Click listener attached to board');
});
