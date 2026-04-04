import React, { useState, useEffect, useCallback } from 'react';
import { Box, Text, useInput, useApp } from 'ink';
import { useWindowSize } from '../hooks/use-window-size.js';
import {
  getGamingModeState,
  isDaemonRunning,
  getVmState,
  getDaemonLog,
  getCurrentGpuDriver,
  readGamingModeConf,
} from '../utils/gaming-mode.js';
import { getScriptDir } from '../utils/system-detect.js';
import { COLORS as CC } from '../utils/colors.js';
import path from 'node:path';
import fs from 'node:fs';
import { runScript } from '../utils/script-runner.js';

interface GamingModeAppProps {
  onBack: () => void;
}

type GamingState =
  | 'idle'
  | 'starting'
  | 'confirm_needed'
  | 'active'
  | 'stopping'
  | 'unknown';

// Map local names to shared COLORS
const CL = {
  border: CC.border,
  title: CC.title,
  subtitle: CC.subtitle,
  active: CC.success,
  inactive: CC.unselected,
  warning: CC.warning,
  danger: CC.error,
  dim: CC.dim,
  selected: CC.selected,
  unselected: CC.unselected,
  info: CC.info,
  badge: CC.badgeBg,
  spinner: CC.warning,
} as const;

// ── Component ─────────────────────────────────────────────────────

const GamingModeApp: React.FC<GamingModeAppProps> = ({ onBack }) => {
  const { exit } = useApp();
  const { columns } = useWindowSize();
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [gameState, setGameState] = useState<GamingState>('unknown');
  const [daemonRunning, setDaemonRunning] = useState(false);
  const [vmState, setVmState] = useState('unknown');
  const [gpuDriver, setGpuDriver] = useState('none');
  const [recentLog, setRecentLog] = useState<string[]>([]);
  const [configLoaded, setConfigLoaded] = useState(false);
  const [gamingConf, setGamingConf] = useState<Record<string, string>>({});
  const [statusOutput, setStatusOutput] = useState<string>('');
  const [showSetup, setShowSetup] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const innerWidth = Math.max(15, columns - 8);

  const scriptDir = getScriptDir();
  const confPath = path.join(scriptDir, 'gaming-mode.conf');

  const refreshState = useCallback(async () => {
    setRefreshing(true);
    const state = getGamingModeState();
    setGameState(state as GamingState);

    const daemon = await isDaemonRunning();
    setDaemonRunning(daemon);

    if (gamingConf.GM_VM_NAME) {
      const vm = await getVmState(gamingConf.GM_VM_NAME);
      setVmState(vm);
    }

    if (gamingConf.GM_GPU_PCI) {
      const driver = getCurrentGpuDriver(gamingConf.GM_GPU_PCI);
      setGpuDriver(driver);
    }

    const log = getDaemonLog();
    if (log) {
      setRecentLog(log.split('\n').slice(-5));
    }

    setTimeout(() => setRefreshing(false), 300);
  }, [gamingConf]);

  // Load config on mount
  useEffect(() => {
    if (!fs.existsSync(confPath)) {
      setConfigLoaded(false);
      return;
    }

    const conf = readGamingModeConf(scriptDir);
    setGamingConf(conf as Record<string, string>);
    setConfigLoaded(true);
    refreshState();

    const interval = setInterval(refreshState, 3000);
    return () => clearInterval(interval);
  }, [confPath, refreshState]);

  const handleAction = async (action: 'start' | 'stop' | 'setup') => {
    if (action === 'setup') {
      setShowSetup(true);
      const setupScript = path.join(scriptDir, 'scripts', 'gaming-mode-setup.sh');
      setStatusOutput('');

      await runScript(setupScript, {
        cwd: scriptDir,
        onOutput: (data) => setStatusOutput((prev) => prev + data),
      });

      setShowSetup(false);
      if (fs.existsSync(confPath)) {
        const conf = readGamingModeConf(scriptDir);
        setGamingConf(conf as Record<string, string>);
        setConfigLoaded(true);
        refreshState();
      }
      return;
    }

    if (action === 'start') {
      if (gameState === 'active') return;
      const script = path.join(scriptDir, 'scripts', 'gaming-mode.sh');
      setStatusOutput('');

      await runScript(script, {
        cwd: scriptDir,
        onOutput: (data) => setStatusOutput((prev) => prev + data),
      });

      refreshState();
      return;
    }

    if (action === 'stop') {
      const stateDir = '/tmp/gaming-mode';
      try {
        fs.mkdirSync(stateDir, { recursive: true });
        fs.writeFileSync(path.join(stateDir, 'action'), 'stop');
      } catch { /* ignore */ }
      setStatusOutput('Stopping gaming mode...');
      refreshState();
      return;
    }
  };

  useInput((_input, key) => {
    if (showSetup) return;
    if (key.escape) { onBack(); return; }

    const maxIndex = gameState === 'active' ? 2 : 3;
    if (key.upArrow) {
      setSelectedIndex((p) => Math.max(0, p - 1));
    } else if (key.downArrow) {
      setSelectedIndex((p) => Math.min(maxIndex, p + 1));
    } else if (key.return) {
      if (selectedIndex <= maxIndex) {
        const actions =
          gameState === 'active'
            ? ['stop', 'setup', 'back']
            : ['start', 'stop', 'setup', 'back'];
        const action = actions[selectedIndex];
        if (action === 'back') onBack();
        else handleAction(action as 'start' | 'stop' | 'setup');
      }
    }
  });

  // ── Not configured state ────────────────────────────────────────

  if (!configLoaded && !showSetup) {
    return (
      <Box flexDirection="column" paddingX={1}>
        <Box flexDirection="column" marginBottom={1}>
          <Box>
            <Text color={CL.border}>{"┌"}</Text>
            <Text color={CL.border}>{"─".repeat(innerWidth)}</Text>
            <Text color={CL.border}>{"┐"}</Text>
          </Box>
          <Box>
            <Text color={CL.border}>{"│"}</Text>
            <Box flexGrow={1} justifyContent="center">
              <Text color={CL.warning} bold>{' Gaming Mode Not Configured '}</Text>
            </Box>
            <Text color={CL.border}>{"│"}</Text>
          </Box>
          <Box>
            <Text color={CL.border}>{"└"}</Text>
            <Text color={CL.border}>{"─".repeat(innerWidth)}</Text>
            <Text color={CL.border}>{"┘"}</Text>
          </Box>
        </Box>
        <Box flexDirection="column" marginBottom={1}>
          <Text>{'The gaming mode setup wizard needs to run first.'}</Text>
          <Text>{''}</Text>
          <Text color={CL.info} bold>{' Press Enter to run setup wizard'}</Text>
          <Text color={CL.dim}>{' ESC: Back to main menu'}</Text>
        </Box>
      </Box>
    );
  }

  // ── Setup wizard running ────────────────────────────────────────

  if (showSetup) {
    return (
      <Box flexDirection="column" paddingX={1} width="100%">
        <Box marginBottom={1}>
          <Text color={CL.title} bold>{' Gaming Mode Setup Wizard'}</Text>
        </Box>
        <Box flexDirection="column">
          {statusOutput.split('\n').filter(Boolean).map((line, i) => (
            <Text key={i}>{line}</Text>
          ))}
          <Box marginTop={1}>
            <Text color={CL.spinner}>{' ⠙ '}</Text>
            <Text color={CL.dim}>{' Running...'}</Text>
          </Box>
        </Box>
      </Box>
    );
  }

  // ── State labels ────────────────────────────────────────────────

  const stateConfig: Record<GamingState, { label: string; color: string; icon: string }> = {
    idle: { label: 'Idle (Linux mode)', color: CL.active, icon: '◉' },
    starting: { label: 'Starting gaming mode...', color: CL.warning, icon: '◌' },
    confirm_needed: { label: 'CONFIRMATION NEEDED', color: CL.warning, icon: '◌' },
    active: { label: 'Gaming Mode ACTIVE', color: CL.danger, icon: '●' },
    stopping: { label: 'Stopping gaming mode...', color: CL.warning, icon: '◌' },
    unknown: { label: 'Unknown', color: CL.inactive, icon: '○' },
  };

  const sc = stateConfig[gameState];
  const actions = gameState === 'active'
    ? [
        { label: 'Stop Gaming Mode', color: CL.danger },
        { label: 'Re-run Setup Wizard', color: CL.info },
        { label: 'Exit (leave active)', color: CL.warning },
      ]
    : [
        { label: 'Start Gaming Mode', color: CL.active },
        { label: 'Stop (Emergency)', color: CL.danger },
        { label: 'Run Setup Wizard', color: CL.info },
        { label: 'Back to Menu', color: CL.warning },
      ];

  return (
    <Box flexDirection="column" paddingX={1}>
      {/* Header */}
      <Box flexDirection="column" marginBottom={1}>
        <Box>
          <Text color={CL.border}>{"┌"}</Text>
          <Text color={CL.border}>{"─".repeat(innerWidth)}</Text>
          <Text color={CL.border}>{"┐"}</Text>
        </Box>
        <Box>
          <Text color={CL.border}>{"│"}</Text>
          <Box flexGrow={1} justifyContent="center">
            <Text color={CL.title} bold>{' Gaming Mode Dashboard '}</Text>
          </Box>
          <Text color={CL.border}>{"│"}</Text>
        </Box>
        <Box>
          <Text color={CL.border}>{"└"}</Text>
          <Text color={CL.border}>{"─".repeat(innerWidth)}</Text>
          <Text color={CL.border}>{"┘"}</Text>
        </Box>
      </Box>

      {/* Status badge */}
      <Box flexDirection="column" marginBottom={1}>
        <Box>
          <Text color={CL.border}>{"┌"}</Text>
          <Text color={CL.border}>{"─".repeat(innerWidth)}</Text>
          <Text color={CL.border}>{"┐"}</Text>
        </Box>
        <Box>
          <Text color={CL.border}>{"│"}</Text>
          <Box flexGrow={1} justifyContent="center">
            <Text color={sc.color as any} bold>
              {` ${sc.icon} ${sc.label} `}
            </Text>
            {refreshing && (
              <Text color={CL.spinner}>{' ⠙ '}</Text>
            )}
          </Box>
          <Text color={CL.border}>{"│"}</Text>
        </Box>
        <Box>
          <Text color={CL.border}>{"└"}</Text>
          <Text color={CL.border}>{"─".repeat(innerWidth)}</Text>
          <Text color={CL.border}>{"┘"}</Text>
        </Box>
      </Box>

      {/* Status cards */}
      <Box flexDirection="column" marginBottom={1}>
        <Box>
          <Text color={CL.info}>{' GPU Driver:   '}</Text>
          <Text color={CL.selected} bold={gpuDriver !== 'none'}>{gpuDriver}</Text>
        </Box>
        <Box>
          <Text color={CL.info}>{' VM State:     '}</Text>
          <Text color={vmState === 'running' ? CL.active : CL.dim}>{vmState}</Text>
        </Box>
        <Box>
          <Text color={CL.info}>{' Daemon:       '}</Text>
          <Text color={daemonRunning ? CL.active : CL.danger}>
            {daemonRunning ? 'running' : 'stopped'}
          </Text>
        </Box>
      </Box>

      {/* Recent log */}
      {recentLog.length > 0 && (
        <Box flexDirection="column" marginBottom={1}>
          <Box>
            <Text color={CL.border}>{"┌"}</Text>
            <Text color={CL.border}>{"─".repeat(Math.max(10, innerWidth - 2))}</Text>
            <Text color={CL.border}>{"┐"}</Text>
          </Box>
          <Box>
            <Text color={CL.border}>{"│"}</Text>
            <Text color={CL.dim}>{' Recent log '}</Text>
            <Box flexGrow={1} />
            <Text color={CL.border}>{"│"}</Text>
          </Box>
          {recentLog.slice(-3).map((line, i) => (
            <Box key={i}>
              <Text color={CL.border}>{"│"}</Text>
              <Text color={CL.dim}>{` ${line.slice(0, Math.max(5, innerWidth - 4))}`}</Text>
              <Box flexGrow={1} />
              <Text color={CL.border}>{"│"}</Text>
            </Box>
          ))}
          <Box>
            <Text color={CL.border}>{"└"}</Text>
            <Text color={CL.border}>{"─".repeat(Math.max(10, innerWidth - 2))}</Text>
            <Text color={CL.border}>{"┘"}</Text>
          </Box>
        </Box>
      )}

      {/* Action menu */}
      <Box flexDirection="column" marginTop={1}>
        {actions.map((item, index) => {
          const isSel = index === selectedIndex;
          return (
            <Box key={index}>
              <Text color={isSel ? (item.color as any) : CL.dim}>
                {isSel ? ' ▸ ' : '   '}
              </Text>
              <Text color={isSel ? (item.color as any) : CL.unselected} bold={isSel}>
                {item.label}
              </Text>
            </Box>
          );
        })}
      </Box>

      <Box marginTop={1}>
        <Text color={CL.dim}>{' ↑↓: Navigate | Enter: Activate | ESC: Back'}</Text>
      </Box>
    </Box>
  );
};

export default GamingModeApp;
