// The TEC Design System bundle is a classic script that reads window.React.
// This module runs first (see index.ts) so the bundle finds the same React the app uses.
import * as React from 'react';

declare global {
  interface Window {
    React: typeof React;
  }
}

window.React = React;
