// Test setup: adds DOM matchers such as toBeInTheDocument(), loads the design system
// (window.TEC) the same way the app does, and cleans up the DOM after each test.
import '@testing-library/jest-dom/vitest';
import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/react';
import '../design-system';

afterEach(() => cleanup());
