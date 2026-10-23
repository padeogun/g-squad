// -------------------------------------------------------------------------------------
// TEC Design System entry point for the app.
//
// Order matters: ES modules run in import order, so React is put on window before the
// bundle (a classic script) reads it. Styles: self-hosted fonts, then the generated tokens,
// then the component styles that use those tokens, then app-level additions.
// -------------------------------------------------------------------------------------
import './react-global';
import './bundle.js';

import '@fontsource/inter/400.css';
import '@fontsource/inter/500.css';
import '@fontsource/inter/600.css';
import '@fontsource/inter/700.css';
import '@fontsource/lexend/400.css';
import '@fontsource/lexend/600.css';
import '@fontsource/lexend/700.css';

import './tokens.css';
import './bundle.css';
import './app.css';

// The bundle assigns its components to window.TEC; re-export them as a typed object so
// screens can write `const { Button, Card } = TEC;`.
export const TEC = window.TEC;

// Logo as a bundled asset URL (hashed file name, cached long-term by Netlify).
export { default as tecMark } from './tec-mark.png';

export type * from './bundle.js';
