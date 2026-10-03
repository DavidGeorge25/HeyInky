// Injected into Ketcher's page by KetcherEditorView.swift. Ketcher sets `window.ketcher`
// when it finishes initializing; Swift waits on `inkyKetcher.ready` before talking to it.
window.inkyKetcher = {
  ready: new Promise((resolve) => {
    const check = () => (window.ketcher && window.ketcher.editor ? resolve(true) : setTimeout(check, 50));
    check();
  }),
  async load(smiles) {
    await window.inkyKetcher.ready;
    // An unreadable structure (the reason the user is here) opens an empty canvas.
    if (smiles) { try { await window.ketcher.setMolecule(smiles); } catch (_) { /* start blank */ } }
    return true;
  },
  async smiles() {
    await window.inkyKetcher.ready;
    return await window.ketcher.getSmiles();
  },
};
