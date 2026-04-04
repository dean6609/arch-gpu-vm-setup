import React, { useState, useEffect, useCallback } from 'react';
import { Box, Text, useApp, useInput } from 'ink';
import { useWindowSize } from '../hooks/use-window-size.js';
import MainMenu from './MainMenu.js';
import GamingModeApp from './GamingModeApp.js';
import ScriptRunner from './ScriptRunner.js';
import {
  detectCpu,
  detectBootloader,
} from '../utils/system-detect.js';
import { getScriptDir } from '../utils/system-detect.js';
import fs from 'node:fs';
import path from 'node:path';

type Screen = 'main' | 'gaming' | 'module';

// ANSI escape sequences for terminal cleanup
const DISABLE_MOUSE = '\x1b[?1002l\x1b[?1006l';
const CLEAR_SCREEN = '\x1b[2J\x1b[H';

/** Clean up terminal state (mouse tracking, screen content). */
function cleanupTerminal() {
  process.stdout.write(DISABLE_MOUSE);
  process.stdout.write(CLEAR_SCREEN);
}

const MainApp: React.FC = () => {
  const { exit } = useApp();
  const [screen, setScreen] = useState<Screen>('main');
  const [currentModule, setCurrentModule] = useState('');
  const [prevScreen, setPrevScreen] = useState<Screen>('main');
  const [systemInfo, setSystemInfo] = useState({
    cpu: 'Detecting...',
    distro: 'Arch',
    bootloader: 'Detecting...',
  });
  const { rows } = useWindowSize();

  useEffect(() => {
    async function loadSystemInfo() {
      const [cpu, bootloader] = await Promise.all([
        detectCpu(),
        detectBootloader(),
      ]);

      setSystemInfo({
        cpu: `${cpu.vendor} (${cpu.vendorId})`,
        distro: 'Arch Linux',
        bootloader: bootloader.type,
      });
    }
    loadSystemInfo();
  }, []);

  // Clear terminal when switching screens to prevent residual output
  useEffect(() => {
    if (screen !== prevScreen) {
      // ANSI: clear screen and move cursor home
      process.stdout.write('\x1B[2J\x1B[H');
      setPrevScreen(screen);
    }
  }, [screen, prevScreen]);

  // Cleanup on unmount: ensure mouse tracking is always disabled
  useEffect(() => {
    return () => {
      cleanupTerminal();
    };
  }, []);

  const handleModuleSelect = useCallback((module: string) => {
    const scriptDir = getScriptDir();
    const modulePath = path.join(scriptDir, 'scripts', 'modules', module);

    if (!fs.existsSync(modulePath)) {
      return;
    }

    setCurrentModule(module);
    setScreen('module');
  }, []);

  const handleGamingMode = useCallback(() => {
    setScreen('gaming');
  }, []);

  const handleExit = useCallback(() => {
    cleanupTerminal();
    exit();
  }, [exit]);

  useInput((_input, key) => {
    if (screen === 'module' && key.escape) {
      setScreen('main');
    }
  });

  if (screen === 'module') {
    return (
      <ScriptRunner
        module={currentModule}
        onBack={() => setScreen('main')}
      />
    );
  }

  if (screen === 'gaming') {
    return <GamingModeApp onBack={() => setScreen('main')} />;
  }

  return (
    <Box flexDirection="column" height={rows}>
      <MainMenu
        systemInfo={systemInfo}
        onModuleSelect={handleModuleSelect}
        onGamingMode={handleGamingMode}
        onExit={handleExit}
      />
      {/* Fill remaining space to push content to top and prevent overlap */}
      <Box flexGrow={1} />
    </Box>
  );
};

export default MainApp;
