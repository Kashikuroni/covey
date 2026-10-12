/* Covey's read-only DOM controller. No project content is evaluated as code. */
(function () {
  const root = document.getElementById('document');
  let query = '', ranges = [], current = -1, positionTimer, restoring = false, interacted = false;
  const post = value => window.webkit.messageHandlers.document.postMessage(value);
  function position() {
    const anchors = Array.from(root.querySelectorAll('[id]'));
    const y = window.scrollY;
    let anchor = anchors[0];
    for (const candidate of anchors) if (candidate.getBoundingClientRect().top + y <= y + 8) anchor = candidate;
    return {anchorID:anchor ? anchor.id : null,offset:anchor ? y - (anchor.getBoundingClientRect().top + y) : 0,progress:y / Math.max(1,document.documentElement.scrollHeight-innerHeight)};
  }
  function restore(value) {
    if (!value) return;
    const node = value.anchorID && document.getElementById(value.anchorID);
    const max = Math.max(0,document.documentElement.scrollHeight-innerHeight);
    const target = node ? node.getBoundingClientRect().top + scrollY + (value.offset || 0) : (value.progress || 0) * max;
    restoring = true;
    scrollTo(0,Math.max(0,Math.min(max,target)));
    requestAnimationFrame(() => { restoring = false; });
  }
  function reveal(id) {
    const node = document.getElementById(id);
    if (node) node.scrollIntoView({block:'start'});
    return !!node;
  }
  function find(text,backwards,scrollToMatch = true) {
    if (text !== query) {
      query = text; current = -1; ranges = [];
      if (text) {
        const walker = document.createTreeWalker(root,NodeFilter.SHOW_TEXT), nodes = [];
        let joined = '', node;
        while ((node = walker.nextNode())) { nodes.push({node,start:joined.length}); joined += node.nodeValue; }
        const escaped = text.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
        const regex = new RegExp(escaped,'giu');
        let match;
        while ((match = regex.exec(joined))) {
          const start = nodes.findLast(n => n.start <= match.index);
          const end = nodes.findLast(n => n.start < match.index + match[0].length);
          if (!start || !end) continue;
          const range = document.createRange();
          range.setStart(start.node,match.index-start.start);
          range.setEnd(end.node,match.index+match[0].length-end.start);
          ranges.push(range);
        }
      }
    }
    if (ranges.length) {
      current = (current + (backwards ? -1 : 1) + ranges.length) % ranges.length;
      if (CSS.highlights && window.Highlight) {
        CSS.highlights.set('document-find',new Highlight(...ranges));
        CSS.highlights.set('document-find-current',new Highlight(ranges[current]));
      }
      const range = ranges[current], rect = range.getBoundingClientRect();
      if (scrollToMatch) scrollBy(0,rect.top - Math.max(24,innerHeight/3));
      if (!CSS.highlights) { const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); }
    } else if (CSS.highlights) { CSS.highlights.delete('document-find'); CSS.highlights.delete('document-find-current'); }
    post({type:'find',current:ranges.length ? current+1 : 0,total:ranges.length});
  }
  root.addEventListener('click',event => {
    const link = event.target.closest('a');
    if (link) { event.preventDefault(); post({type:'link',reference:link.getAttribute('href') || ''}); }
  });
  for (const name of ['pointerdown','wheel','keydown']) document.addEventListener(name,() => { interacted = true; post({type:'focused'}); },{passive:true});
  window.addEventListener('scroll',() => {
    if (restoring) return;
    clearTimeout(positionTimer);
    positionTimer = setTimeout(() => post({type:'position',value:position()}),150);
  },{passive:true});
  window.CoveyDocument = {
    render(value) {
      clearTimeout(positionTimer); interacted = false;
      const previousQuery = query;
      root.innerHTML = value.html;
      document.documentElement.className = value.theme;
      if (window.Prism) Prism.highlightAllUnder(root);
      query = ''; ranges = []; current = -1;
      const reset = () => {
        if (value.fragment && reveal(value.fragment)) return;
        if (value.position) restore(value.position); else scrollTo(0,0);
      };
      requestAnimationFrame(() => { reset(); if (previousQuery) find(previousQuery,false,false); });
      for (const image of root.querySelectorAll('img')) image.addEventListener('load',() => { if (!interacted) reset(); },{once:true});
      post({type:'rendered'});
    },
    theme(value) { document.documentElement.className = value; },
    command(value) {
      if (value.type === 'anchor') reveal(value.id);
      if (value.type === 'restore') restore(value.position);
      if (value.type === 'find') find(value.query,value.backwards);
      if (value.type === 'focus') root.focus({preventScroll:true});
    }
  };
  post({type:'ready'});
})();
