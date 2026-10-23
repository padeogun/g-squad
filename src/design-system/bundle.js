/* @ds-bundle: {"format":4,"namespace":"TEC","components":[{"name":"Icon"},{"name":"Button"},{"name":"Chip"},{"name":"Notice"},{"name":"Progress"},{"name":"StatTile"},{"name":"DataTable"},{"name":"Card"},{"name":"SectionHeading"},{"name":"SideNav"},{"name":"TextField"},{"name":"SelectField"},{"name":"Checkbox"},{"name":"Segmented"},{"name":"Stepper"},{"name":"RestrictedPanel"},{"name":"ServiceGrid"},{"name":"DateBlock"},{"name":"NewsletterHeader"},{"name":"GatheringRow"},{"name":"WinsBanner"},{"name":"EventPost"},{"name":"Slide"},{"name":"ValueTag"},{"name":"ValuesStrip"}]} */
/* TEC Design System components. Classic script: reads window.React, assigns window.TEC. No network, no imports. */
(function () {
  var React = window.React;
  var h = React.createElement;

  /* Joins class names, skipping empty ones. */
  function cx() {
    return Array.prototype.filter.call(arguments, Boolean).join(' ');
  }

  /* Copies props except the listed keys, so extra attributes reach the DOM element. */
  function rest(props, omit) {
    var out = {};
    for (var k in props) {
      if (Object.prototype.hasOwnProperty.call(props, k) && omit.indexOf(k) === -1) out[k] = props[k];
    }
    return out;
  }

  /* ---------- Icon: 24px grid, 2px round strokes, drawn in currentColor ---------- */
  var ICONS = {
    lock: [['rect', { x: 4, y: 11, width: 16, height: 10, rx: 2 }], ['path', { d: 'M8 11V7a4 4 0 0 1 8 0v4' }]],
    alert: [['circle', { cx: 12, cy: 12, r: 9 }], ['path', { d: 'M12 8v5' }], ['path', { d: 'M12 16h.01' }]],
    info: [['circle', { cx: 12, cy: 12, r: 9 }], ['path', { d: 'M12 11v5' }], ['path', { d: 'M12 8h.01' }]],
    check: [['path', { d: 'M5 12.5l4.5 4.5L19 7.5' }]],
    calendar: [['rect', { x: 3, y: 4, width: 18, height: 17, rx: 2 }], ['path', { d: 'M3 10h18M8 2v4M16 2v4' }]],
    users: [['circle', { cx: 9, cy: 8, r: 3.5 }], ['path', { d: 'M2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 7M18 14.5a6.5 6.5 0 0 1 3.5 5.5' }]],
    list: [['path', { d: 'M4 6h16M4 12h16M4 18h10' }]],
    plus: [['path', { d: 'M12 5v14M5 12h14' }]],
    close: [['path', { d: 'M6 6l12 12M18 6L6 18' }]],
    download: [['path', { d: 'M12 4v11M7 10l5 5 5-5M5 20h14' }]],
    more: [['circle', { cx: 5, cy: 12, r: 1.5 }], ['circle', { cx: 12, cy: 12, r: 1.5 }], ['circle', { cx: 19, cy: 12, r: 1.5 }]],
    clock: [['circle', { cx: 12, cy: 12, r: 9 }], ['path', { d: 'M12 7v5l3 2' }]],
    mail: [['rect', { x: 3, y: 5, width: 18, height: 14, rx: 2 }], ['path', { d: 'M3 7l9 6 9-6' }]],
    pin: [['path', { d: 'M12 21s-7-6.2-7-11.5a7 7 0 0 1 14 0C19 14.8 12 21 12 21z' }], ['circle', { cx: 12, cy: 9.5, r: 2.5 }]]
  };
  function Icon(p) {
    var size = p.size || 20;
    var parts = ICONS[p.name] || ICONS.info;
    return h('svg', {
      className: cx('tec-icon', p.className), width: size, height: size, viewBox: '0 0 24 24',
      fill: 'none', stroke: 'currentColor', strokeWidth: 2, strokeLinecap: 'round', strokeLinejoin: 'round',
      role: p.label ? 'img' : undefined, 'aria-label': p.label || undefined, 'aria-hidden': p.label ? undefined : 'true'
    }, parts.map(function (e, i) { return h(e[0], Object.assign({ key: i }, e[1])); }));
  }
  Icon.names = Object.keys(ICONS);

  /* ---------- Button: primary (navy), secondary (outline), lime, quiet ---------- */
  function Button(p) {
    var variant = p.variant || 'primary';
    var props = rest(p, ['variant', 'size', 'icon', 'children', 'className', 'href']);
    props.className = cx('tec-btn', 'tec-btn-' + variant, p.size === 'sm' && 'tec-btn-sm', p.className);
    var kids = [p.icon ? h(Icon, { key: 'i', name: p.icon, size: 18 }) : null, p.children];
    if (p.href) { props.href = p.href; return h('a', props, kids); }
    if (!props.type) props.type = 'button';
    return h('button', props, kids);
  }

  /* ---------- Chip: a status word on a soft ground ---------- */
  function Chip(p) {
    return h('span', { className: cx('tec-chip', 'tec-chip-' + (p.tone || 'info'), p.className) },
      p.icon ? h(Icon, { name: p.icon, size: 14 }) : null, p.children);
  }

  /* ---------- Notice: an inline message with an icon ---------- */
  function Notice(p) {
    var tone = p.tone || 'info';
    return h('div', { className: cx('tec-notice', 'tec-notice-' + tone), role: tone === 'danger' ? 'alert' : 'status' },
      h(Icon, { name: tone === 'info' ? 'info' : tone === 'ok' ? 'check' : 'alert' }),
      h('div', null, p.title ? h('b', null, p.title) : null, p.children));
  }

  /* ---------- Progress: completion against a total ---------- */
  function Progress(p) {
    var max = p.max || 100;
    var value = Math.max(0, Math.min(p.value || 0, max));
    return h('div', { className: 'tec-progress' },
      h('div', { className: 'tec-progress-head' }, h('b', null, p.label), h('span', null, value + ' of ' + max)),
      h('div', { className: 'tec-progress-track', role: 'progressbar', 'aria-valuemin': 0, 'aria-valuemax': max, 'aria-valuenow': value, 'aria-label': p.label },
        h('span', { className: 'tec-progress-fill', style: { width: (value / max * 100) + '%' } })));
  }

  /* ---------- StatTile: one headline number ---------- */
  function StatTile(p) {
    var tone = p.tone && p.tone !== 'default' ? 'tec-stat-' + p.tone : null;
    return h('div', { className: cx('tec-stat', tone) },
      h('span', { className: 'tec-stat-label' }, p.label),
      h('span', { className: 'tec-stat-value' }, p.value, p.suffix ? h('small', null, ' ' + p.suffix) : null),
      p.note ? h('span', { className: 'tec-stat-note' }, p.note) : null);
  }

  /* ---------- DataTable: columns and rows; cells may hold Chips ---------- */
  function DataTable(p) {
    var cols = p.columns || [];
    return h('div', { className: 'tec-table-wrap' },
      h('table', { className: 'tec-table' },
        p.caption ? h('caption', null, p.caption) : null,
        h('thead', null, h('tr', null, cols.map(function (c) {
          return h('th', { key: c.key, scope: 'col', className: c.align === 'right' ? 'num' : undefined }, c.label);
        }))),
        h('tbody', null, (p.rows || []).map(function (r, i) {
          return h('tr', { key: r.id || i }, cols.map(function (c) {
            return h('td', { key: c.key, className: c.align === 'right' ? 'num' : undefined }, r[c.key]);
          }));
        }))));
  }

  /* ---------- Card: a titled panel ---------- */
  function Card(p) {
    return h('section', { className: cx('tec-card', p.tone === 'tint' && 'tec-card-tint', p.className) },
      p.title || p.action ? h('div', { className: 'tec-card-head' },
        p.title ? h('h2', { className: 'tec-card-title' }, p.title) : null, p.action || null) : null,
      p.children);
  }

  /* ---------- SectionHeading: eyebrow, title, lime rule ---------- */
  function SectionHeading(p) {
    return h('div', { className: 'tec-heading' },
      p.eyebrow ? h('span', { className: 'tec-eyebrow' }, p.eyebrow) : null,
      h('h2', null, p.title),
      p.rule === false ? null : h('span', { className: 'tec-rule', 'aria-hidden': 'true' }),
      p.children ? h('p', null, p.children) : null);
  }

  /* ---------- SideNav: the app's navy sidebar ---------- */
  function SideNav(p) {
    return h('nav', { className: 'tec-nav', 'aria-label': p.label || 'Main' },
      h('div', { className: 'tec-nav-brand' },
        p.logo ? h('img', { className: 'tec-logo', src: p.logo, alt: 'The Elevation Church', width: 40, height: 40 }) : null,
        h('span', { className: 'tec-nav-church' }, p.church || 'The Elevation Church · Manchester'),
        h('span', { className: 'tec-nav-app' }, p.app || 'G-Squad Planner'),
        h('span', { className: 'tec-rule', 'aria-hidden': 'true' })),
      (p.groups || []).map(function (g) {
        return h('div', { className: 'tec-nav-group', key: g.label },
          h('span', { className: 'tec-nav-label' }, g.label),
          g.items.map(function (it) {
            return h('a', { key: it.label, href: it.href || '#', 'aria-current': it.current ? 'page' : undefined }, it.label);
          }));
      }));
  }

  /* ---------- Form fields: a visible label above every control ---------- */
  function TextField(p) {
    var props = rest(p, ['label', 'hint', 'className']);
    props.className = 'tec-input';
    if (!props.type) props.type = 'text';
    return h('label', { className: cx('tec-field', p.className), htmlFor: p.id },
      h('span', null, p.label, p.hint ? h('span', { className: 'tec-hint' }, ' ' + p.hint) : null),
      h('input', props));
  }
  function SelectField(p) {
    var props = rest(p, ['label', 'hint', 'options', 'className']);
    props.className = 'tec-select';
    return h('label', { className: cx('tec-field', p.className), htmlFor: p.id },
      h('span', null, p.label, p.hint ? h('span', { className: 'tec-hint' }, ' ' + p.hint) : null),
      h('select', props, (p.options || []).map(function (o) {
        var v = typeof o === 'string' ? o : o.value;
        return h('option', { key: v, value: v }, typeof o === 'string' ? o : o.label);
      })));
  }
  function Checkbox(p) {
    var props = rest(p, ['label', 'className']);
    props.type = 'checkbox';
    return h('label', { className: cx('tec-check', p.className) }, h('input', props), p.label);
  }

  /* ---------- Segmented: two to four exclusive choices, e.g. Served / No-show ---------- */
  function Segmented(p) {
    var opts = p.options || [];
    var st = React.useState(p.defaultValue != null ? p.defaultValue : opts[0]);
    var value = p.value != null ? p.value : st[0];
    function pick(o) { if (p.onChange) p.onChange(o); else st[1](o); }
    return h('div', { className: 'tec-seg', role: 'group', 'aria-label': p.label },
      opts.map(function (o) {
        return h('button', { key: o, type: 'button', 'aria-pressed': o === value ? 'true' : 'false', onClick: function () { pick(o); } }, o);
      }));
  }

  /* ---------- Stepper: an ordered approval or status flow ---------- */
  function Stepper(p) {
    return h('ol', { className: 'tec-steps', 'aria-label': p.label },
      (p.steps || []).map(function (s, i) {
        var state = s.state || 'todo';
        return h('li', { key: i, className: cx('tec-step', 'tec-step-' + state), 'aria-current': state === 'current' ? 'step' : undefined },
          h('span', { className: 'tec-step-num' }, state === 'done' ? h(Icon, { name: 'check', size: 14 }) : i + 1),
          h('span', null, h('b', null, s.label), s.note ? h('span', { className: 'n' }, s.note) : null));
      }));
  }

  /* ---------- RestrictedPanel: special category data with its audience stated ---------- */
  function RestrictedPanel(p) {
    return h('section', { className: 'tec-restricted' },
      h('div', { className: 'tec-restricted-head' }, h(Icon, { name: 'lock', size: 22 }), h('h3', null, p.title || 'Restricted')),
      h('p', null, p.audience),
      p.children);
  }

  /* ---------- ServiceGrid: the Sunday flow of programme; end times worked out ---------- */
  function addMinutes(hhmm, mins) {
    var parts = String(hhmm).split(':');
    var t = parseInt(parts[0], 10) * 60 + parseInt(parts[1], 10) + mins;
    var hh = Math.floor(t / 60) % 24, mm = t % 60;
    return (hh < 10 ? '0' : '') + hh + ':' + (mm < 10 ? '0' : '') + mm;
  }
  function ServiceGrid(p) {
    return h('div', { className: 'tec-table-wrap' },
      h('table', { className: 'tec-grid' },
        p.title ? h('caption', null, p.title) : null,
        h('thead', null, h('tr', null,
          h('th', { scope: 'col' }, 'Activity'), h('th', { scope: 'col' }, 'Time'),
          h('th', { scope: 'col' }, 'Led by'), h('th', { scope: 'col' }, 'Duration'))),
        h('tbody', null, (p.rows || []).map(function (r, i) {
          return h('tr', { key: i },
            h('td', { className: 'act' }, r.activity, r.sub ? h('span', { className: 'sub' }, r.sub) : null),
            h('td', null, r.start + ' – ' + addMinutes(r.start, r.minutes)),
            h('td', null, h('span', { className: cx('tec-led', r.person && 'tec-led-person') }, r.led)),
            h('td', null, r.minutes + ' min'));
        }))));
  }

  /* ---------- DateBlock: day over month, navy ---------- */
  function DateBlock(p) {
    return h('span', { className: 'tec-date', role: 'img', 'aria-label': p.day + ' ' + p.month },
      h('b', { 'aria-hidden': 'true' }, p.day), h('span', { 'aria-hidden': 'true' }, p.month));
  }

  /* ---------- Newsletter blocks ---------- */
  function NewsletterHeader(p) {
    return h('header', { className: 'tec-nl-head' },
      p.logo ? h('img', { className: 'tec-logo tec-logo-lg', src: p.logo, alt: 'The Elevation Church', width: 56, height: 56 }) : null,
      h('span', { className: 'tec-nl-church' }, p.church || 'The Elevation Church · Manchester'),
      h('span', { className: 'tec-nl-title' }, p.title || 'The Greatness Brief'),
      h('span', { className: 'tec-nl-sub' }, p.subtitle || 'Monthly Newsletter'));
  }
  function GatheringRow(p) {
    return h('article', { className: 'tec-gather' },
      h(DateBlock, { day: p.day, month: p.month }),
      h('div', { className: 'tec-gather-body' },
        p.tag ? h('span', { className: 'tec-gather-tag' }, p.tag) : null,
        h('h3', { className: 'tec-gather-title' }, p.title),
        p.text ? h('p', { className: 'tec-gather-text' }, p.text) : null,
        h('div', { className: 'tec-gather-actions' },
          h(Button, { size: 'sm' }, p.rsvpLabel || "I'll be there"),
          p.going != null ? h('span', null, p.going + ' going') : null,
          h(Button, { variant: 'quiet', size: 'sm', icon: 'plus' }, 'Add to calendar'))));
  }
  function WinsBanner(p) {
    return h('section', { className: 'tec-wins' },
      h('span', null, p.label || 'Wins & Testimonies'),
      h('p', null, p.children));
  }

  /* ---------- EventPost: a square social post ---------- */
  function EventPost(p) {
    return h('article', { className: 'tec-post', 'aria-label': p.title },
      h('span', { className: 'tec-post-pill', 'aria-hidden': 'true' }),
      h('span', { className: 'tec-post-tag' }, p.tag || 'Event'),
      h('h3', { className: 'tec-post-title' }, p.title),
      h('div', { className: 'tec-post-meta' },
        h('b', null, p.date), p.time ? h('span', null, p.time) : null, p.place ? h('span', null, p.place) : null),
      h('span', { className: 'tec-post-foot' }, p.footer || 'The Elevation Church · Manchester'));
  }

  /* ---------- Slide: 16:9 title or content slide ---------- */
  function Slide(p) {
    var kind = p.kind || 'title';
    return h('section', { className: cx('tec-slide', 'tec-slide-' + kind), 'aria-label': p.title },
      h('span', { className: 'tec-slide-bar', 'aria-hidden': 'true' }),
      p.eyebrow ? h('span', { className: 'eb' }, p.eyebrow) : null,
      h('h3', null, p.title),
      p.subtitle ? h('p', null, p.subtitle) : null,
      p.points ? h('ul', null, p.points.map(function (t, i) { return h('li', { key: i }, t); })) : null,
      h('span', { className: 'tec-slide-foot' }, p.footer || 'The Elevation Church · Manchester'));
  }

  /* ---------- Core values (ASHLIE): TEC's own wording, from the G-Squad handbook ---------- */
  var ASHLIE = [
    { letter: 'A', name: 'Accountability', behaviour: 'We serve responsibly: owning our roles, our actions and our commitments without excuses.' },
    { letter: 'S', name: 'Service', behaviour: 'We serve faithfully: showing up consistently for God\u2019s people with a willing heart, every time.' },
    { letter: 'H', name: 'Humility', behaviour: 'We serve selflessly: never placing personal ambition above the shared mission of the church.' },
    { letter: 'L', name: 'Love', behaviour: 'We serve people genuinely: every interaction reflects the love of Christ, not just politeness.' },
    { letter: 'I', name: 'Integrity', behaviour: 'We serve transparently: who we are privately matches how we present ourselves publicly.' },
    { letter: 'E', name: 'Excellence', behaviour: 'We serve exceptionally: giving our best because God and His people deserve our best always.' }
  ];
  function findValue(letter) {
    for (var i = 0; i < ASHLIE.length; i++) if (ASHLIE[i].letter === letter) return ASHLIE[i];
    return ASHLIE[0];
  }

  /* ValueTag: one value as a letter disc and its name; never a score. */
  function ValueTag(p) {
    var v = findValue(p.letter);
    return h('span', { className: 'tec-value' },
      h('span', { className: 'tec-value-letter', 'aria-hidden': 'true' }, v.letter),
      h('span', null, p.name || v.name));
  }

  /* ValuesStrip: all six values in order, the letters spelling ASHLIE. */
  function ValuesStrip(p) {
    var vals = p.values || ASHLIE;
    return h('section', { className: cx('tec-values', p.compact && 'tec-values-compact'), 'aria-label': p.label || 'Our core values: ASHLIE' },
      vals.map(function (v) {
        return h('div', { className: 'tec-values-item', key: v.letter },
          h('span', { className: 'tec-values-letter', 'aria-hidden': 'true' }, v.letter),
          h('b', null, v.name),
          p.compact ? null : h('span', { className: 'tec-values-text' }, v.behaviour));
      }));
  }

  var TEC = {
    Icon: Icon, Button: Button, Chip: Chip, Notice: Notice, Progress: Progress, StatTile: StatTile,
    DataTable: DataTable, Card: Card, SectionHeading: SectionHeading, SideNav: SideNav,
    TextField: TextField, SelectField: SelectField, Checkbox: Checkbox, Segmented: Segmented,
    Stepper: Stepper, RestrictedPanel: RestrictedPanel, ServiceGrid: ServiceGrid, DateBlock: DateBlock,
    NewsletterHeader: NewsletterHeader, GatheringRow: GatheringRow, WinsBanner: WinsBanner,
    EventPost: EventPost, Slide: Slide, ValueTag: ValueTag, ValuesStrip: ValuesStrip, ASHLIE: ASHLIE
  };
  window.TEC = Object.assign(window.TEC || {}, TEC);
})();
