import React, { useState, useEffect, useCallback, useRef } from 'react';
import { Box, Text, useInput } from 'ink';
import { useWindowSize } from '../hooks/use-window-size.js';
import { COLORS as C } from '../utils/colors.js';

// ── SGR mouse mode ────────────────────────────────────────────────

const ENABLE_MOUSE = '\x1b[?1002h\x1b[?1006h';
const DISABLE_MOUSE = '\x1b[?1002l\x1b[?1006l';

// ── Menu entry definition ─────────────────────────────────────────

interface MenuEntry {
  key: string;
  badge: string;
  label: string;
  module?: string;
  action?: 'gaming' | 'exit';
  section?: string;
}

interface MainMenuProps {
  systemInfo: {
    cpu: string;
    distro: string;
    bootloader: string;
  };
  onModuleSelect: (module: string) => void;
  onGamingMode: () => void;
  onExit: () => void;
}

// ── Menu items with sections ──────────────────────────────────────

const MENU_ITEMS: MenuEntry[] = [
  { key: '1', badge: '01', label: 'Prerequisites Check', module: '00_prereq_check.sh', section: 'SETUP' },
  { key: '2', badge: '02', label: 'BIOS Configuration Guide', module: '01_bios_guide.sh' },
  { key: '3', badge: '03', label: 'Virtualization Setup (QEMU/KVM/libvirt)', module: '02_virtualization.sh' },
  { key: '4', badge: '04', label: 'VFIO / GPU Passthrough', module: '03_vfio_setup.sh' },
  { key: '5', badge: '05', label: 'GPU Binding Management', module: '04_gpu_bind.sh' },
  { key: '6', badge: '06', label: 'Compile QEMU (anti-detection)', module: '05_qemu_patched.sh' },
  { key: '7', badge: '07', label: 'Compile EDK2/OVMF (firmware)', module: '06_edk2_patched.sh' },
  { key: '8', badge: '08', label: 'Deploy Windows VM', module: '08_deploy_vm.sh' },
  { key: '9', badge: '09', label: 'VirtIO Network Driver', module: '07_virtio_network.sh', section: 'OPTIMIZE' },
  { key: '10', badge: '10', label: 'Fortnite / EAC Patches', module: '09_fortnite_patches.sh' },
  { key: '11', badge: '11', label: 'System Diagnostics', module: '10_diagnostics.sh', section: 'TOOLS' },
  { key: '12', badge: '12', label: 'Uninstall Everything', module: '11_uninstall.sh' },
  { key: 'G', badge: '\u23F5', label: 'Gaming Mode', action: 'gaming', section: 'MODE' },
  { key: '0', badge: '\u2715', label: 'Exit', action: 'exit', section: '' },
];

// ── Component ─────────────────────────────────────────────────────

const MainMenu: React.FC<MainMenuProps> = ({
  systemInfo,
  onModuleSelect,
  onGamingMode,
  onExit,
}) => {
  const { columns } = useWindowSize();
  const [selectedIndex, setSelectedIndex] = useState(0);
  const lastClickRef = useRef(0);

  // ── Enable mouse tracking ──────────────────────────────────────

  useEffect(() => {
    process.stdout.write(ENABLE_MOUSE);
    return () => {
      process.stdout.write(DISABLE_MOUSE);
    };
  }, []);

  // ── Mouse handler ──────────────────────────────────────────────

  const activateItem = useCallback((item: MenuEntry) => {
    if (item.action === 'exit') onExit();
    else if (item.action === 'gaming') onGamingMode();
    else if (item.module) onModuleSelect(item.module);
  }, [onModuleSelect, onGamingMode, onExit]);

  useEffect(() => {
    const onData = (data: Buffer) => {
      const text = data.toString();
      const m = text.match(/\x1b\[<(\d+);(\d+);(\d+)([mM])/);
      if (!m) return;

      const btn = parseInt(m[1], 10);
      const y = parseInt(m[3], 10);
      const type = m[4];

      // Terminal row where menu content starts (1-indexed)
      const menuStartRow = 8;

      // Left click (btn 0, release)
      if (type === 'm' && btn === 0) {
        const clickedVisualRow = y - menuStartRow;

        // Walk through MENU_ITEMS to find which item corresponds to this visual row
        let visualRow = 0;
        let clickedIdx = -1;
        for (let i = 0; i < MENU_ITEMS.length; i++) {
          const item = MENU_ITEMS[i];
          const hasDivider = item.section && (i === 0 || MENU_ITEMS[i - 1]?.section !== item.section);
          if (hasDivider) {
            if (visualRow === clickedVisualRow) {
              // Clicked on a divider — ignore
              return;
            }
            visualRow++;
          }
          if (visualRow === clickedVisualRow) {
            clickedIdx = i;
            break;
          }
          visualRow++;
        }

        if (clickedIdx < 0) return;

        const now = Date.now();

        if (clickedIdx === selectedIndex && now - lastClickRef.current < 500) {
          // Double click → activate
          activateItem(MENU_ITEMS[clickedIdx]);
        } else {
          // Single click → select
          setSelectedIndex(clickedIdx);
          lastClickRef.current = now;
        }
      }
    };

    process.stdin.on('data', onData);
    return () => {
      process.stdin.off('data', onData);
    };
  }, [selectedIndex, activateItem]);

  // ── Keyboard handler ───────────────────────────────────────────

  useInput((_input, key) => {
    if (key.upArrow || _input === 'k') {
      setSelectedIndex(prev => Math.max(0, prev - 1));
    } else if (key.downArrow || _input === 'j') {
      setSelectedIndex(prev => Math.min(MENU_ITEMS.length - 1, prev + 1));
    } else if (key.return) {
      activateItem(MENU_ITEMS[selectedIndex]);
    } else if (_input === '0') {
      onExit();
    } else if (_input.toLowerCase() === 'g') {
      onGamingMode();
    }
  });

  // ── Render ─────────────────────────────────────────────────────

  const innerWidth = Math.max(20, columns - 4);
  const infoText = `CPU: ${systemInfo.cpu} | Distro: ${systemInfo.distro} | Boot: ${systemInfo.bootloader}`;
  const displayInfo = infoText.slice(0, Math.max(10, columns - 2));

  return (
    <Box flexDirection="column" paddingX={1}>
      {/* Header */}
      <Box flexDirection="column" marginBottom={1}>
        <Box>
          <Text color={C.border}>{"┌"}</Text>
          <Text color={C.border}>{"─".repeat(innerWidth)}</Text>
          <Text color={C.border}>{"┐"}</Text>
        </Box>
        <Box>
          <Text color={C.border}>{"│"}</Text>
          <Box flexGrow={1} justifyContent="center">
            <Text color={C.title} bold>{' GPU Passthrough Gaming '}</Text>
          </Box>
          <Text color={C.border}>{"│"}</Text>
        </Box>
        <Box>
          <Text color={C.border}>{"│"}</Text>
          <Box flexGrow={1} justifyContent="center">
            <Text color={C.subtitle}>{' Arch Linux Edition '}</Text>
          </Box>
          <Text color={C.border}>{"│"}</Text>
        </Box>
        <Box>
          <Text color={C.border}>{"└"}</Text>
          <Text color={C.border}>{"─".repeat(innerWidth)}</Text>
          <Text color={C.border}>{"┘"}</Text>
        </Box>
      </Box>

      {/* System info */}
      <Box marginBottom={1}>
        <Text color={C.border} dimColor>{displayInfo}</Text>
      </Box>

      {/* Menu items with section dividers */}
      <Box flexDirection="column">
        {MENU_ITEMS.map((item, i) => {
          const isSel = i === selectedIndex;
          const hasDivider = item.section && (i === 0 || MENU_ITEMS[i - 1]?.section !== item.section);

          return (
            <React.Fragment key={item.key}>
              {hasDivider && (
                <Box>
                  <Text color={C.section}>{`── ${item.section} ──`}</Text>
                </Box>
              )}
              <MenuRow item={item} isSelected={isSel} />
            </React.Fragment>
          );
        })}
      </Box>

      {/* Footer */}
      <Box marginTop={1}>
        <Text color={C.dim} dimColor>
          {' ↑↓/j k: Navigate | Enter: Activate | Click: Select | DblClick: Enter'}
        </Text>
      </Box>
    </Box>
  );
};

// ── Individual menu row component ─────────────────────────────────

const MenuRow: React.FC<{ item: MenuEntry; isSelected: boolean }> = React.memo(({ item, isSelected }) => {
  const badgeBg = isSelected ? C.badgeBgSel : C.badgeBg;
  const badgeText = isSelected ? C.badgeTextSel : C.badgeText;
  const labelColor = isSelected ? C.selected : C.unselected;
  const arrow = isSelected ? '▸' : ' ';

  // Normalize all badges to a fixed 2-character display.
  // Two-char badges ("01") used as-is. Single-char Unicode symbols
  // (\u23F5 play, \u2715 X) get a leading space for centering.
  const displayBadge = item.badge.length <= 1 ? ` ${item.badge}` : item.badge.slice(0, 2);

  return (
    <Box>
      <Text color={C.arrow}>{arrow}</Text>
      <Text> </Text>
      <Box width={6} justifyContent="center">
        <Text backgroundColor={badgeBg} color={badgeText} bold>{` ${displayBadge} `}</Text>
      </Box>
      <Text> </Text>
      <Text color={labelColor} bold={isSelected}>
        {item.label}
      </Text>
    </Box>
  );
});

export default MainMenu;
