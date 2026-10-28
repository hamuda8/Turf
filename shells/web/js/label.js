// Print button for shipping labels (inline scripts are blocked by our CSP).
document.getElementById('print')?.addEventListener('click', () => window.print());
