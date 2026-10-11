/* Covey's shared markdown-it 14.1.0 adapter, used by JavaScriptCore. */
(function () {
  const md = markdownit({html:false,linkify:false,typographer:false});
  function escape(s) { return md.utils.escapeHtml(s); }
  function plain(children) {
    return (children || []).map(t => {
      if (t.type === 'text' || t.type === 'code_inline') return t.content;
      if (t.type === 'softbreak' || t.type === 'hardbreak') return '\n';
      if (t.type === 'image') return t.content;
      return '';
    }).join('');
  }
  md.renderer.rules.image = function(tokens,index,options,env,self) {
    const token = tokens[index], src = token.attrGet('src') || '';
    token.attrSet('src','covey-document://image/?ref=' + encodeURIComponent(src));
    token.attrSet('loading','lazy');
    return self.renderToken(tokens,index,options);
  };
  globalThis.CoveyMarkdown = {
    parse(source,sourceMode) {
      if (sourceMode) return {html:'<pre class="source" id="source"><code>' + escape(source) + '</code></pre>',text:source,headings:[]};
      const tokens = md.parse(source,{}), counts = {}, headings = [], text = [];
      for (let i=0;i<tokens.length;i++) {
        const token = tokens[i];
        if (token.type === 'heading_open') {
          const title = plain(tokens[i+1].children), slug = title.toLowerCase().replace(/[^\p{L}\p{N}_\-\s]/gu,'').trim().replace(/\s+/g,'-') || 'heading';
          const n = counts[slug] || 0; counts[slug] = n+1;
          const id = slug + (n ? '-' + n : '');
          token.attrSet('id',id);
          headings.push({id,text:title,level:Number(token.tag.slice(1))});
        } else if (token.block && token.nesting === 1 && token.map && token.type !== 'table_open') {
          // Block identity is content based, so inserting preceding lines does not
          // change the position anchor of an unchanged paragraph or code block.
          const content = tokens[i+1] ? tokens[i+1].content : token.content;
          let hash = 2166136261;
          for (const c of content) hash = Math.imul(hash ^ c.codePointAt(0),16777619);
          const base = 'block-' + (hash >>> 0).toString(16), n = counts[base] || 0;
          counts[base] = n+1; token.attrSet('id',base + (n ? '-' + n : ''));
        }
        if (token.type === 'inline') {
          const children = token.children || [];
          const first = children[0];
          if (first && first.type === 'text' && /^\[[ xX]\] /.test(first.content) && tokens.slice(0,i).reverse().find(t => t.type === 'list_item_open' || t.type === 'list_item_close')?.type === 'list_item_open') {
            const checked = first.content[1].toLowerCase() === 'x';
            first.content = first.content.slice(4);
            const checkbox = new token.constructor('html_inline','',0);
            checkbox.content = '<input type="checkbox" disabled' + (checked ? ' checked' : '') + ' aria-label="Task status"> ';
            children.unshift(checkbox);
          }
          text.push(plain(children));
        } else if (token.type === 'fence' || token.type === 'code_block') { text.push(token.content.trimEnd()); }
      }
      return {html:md.renderer.render(tokens,md.options,{}),text:text.join('\n'),headings};
    }
  };
})();
