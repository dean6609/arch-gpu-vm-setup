import React from 'react';
import { render } from 'ink';
import MainApp from './components/MainApp.js';

// Ensure non-root check
if (process.getuid?.() === 0) {
  console.error(
    '\x1b[31m\x1b[1m[!] Do not run as root. Run as a regular user and enter password when prompted.\x1b[0m',
  );
  process.exit(1);
}

// ANSI escape sequences for terminal cleanup
const DISABLE_MOUSE = '\x1b[?1002l\x1b[?1006l';
const CLEAR_SCREEN = '\x1b[2J\x1b[H\x1b[0m';

const { waitUntilExit } = render(<MainApp />);
await waitUntilExit();

// Clean up terminal state before exiting
process.stdout.write(DISABLE_MOUSE);
process.stdout.write(CLEAR_SCREEN);
process.exit(0);
