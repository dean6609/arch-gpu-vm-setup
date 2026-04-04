import React from 'react';
import { test, expect } from 'vitest';
import { render } from 'ink-testing-library';
import MainMenu from './MainMenu.js';

test('renders the header box', () => {
  const { lastFrame } = render(
    <MainMenu
      systemInfo={{ cpu: 'AMD (AuthenticAMD)', distro: 'Arch Linux', bootloader: 'systemd-boot' }}
      onModuleSelect={() => {}}
      onGamingMode={() => {}}
      onExit={() => {}}
    />,
  );

  const frame = lastFrame();
  expect(frame).toContain('┌');
  expect(frame).toContain('┐');
  expect(frame).toContain('└');
  expect(frame).toContain('┘');
  expect(frame).toContain('GPU Passthrough Gaming');
  expect(frame).toContain('Arch Linux Edition');
});

test('renders all 14 menu items', () => {
  const { lastFrame } = render(
    <MainMenu
      systemInfo={{ cpu: 'AMD', distro: 'Arch', bootloader: 'grub' }}
      onModuleSelect={() => {}}
      onGamingMode={() => {}}
      onExit={() => {}}
    />,
  );

  const frame = lastFrame();
  // Verify all menu labels are present
  expect(frame).toContain('Prerequisites Check');
  expect(frame).toContain('BIOS Configuration Guide');
  expect(frame).toContain('Virtualization Setup');
  expect(frame).toContain('VFIO / GPU Passthrough');
  expect(frame).toContain('GPU Binding Management');
  expect(frame).toContain('Compile QEMU');
  expect(frame).toContain('Compile EDK2/OVMF');
  expect(frame).toContain('Deploy Windows VM');
  expect(frame).toContain('VirtIO Network Driver');
  expect(frame).toContain('Fortnite / EAC Patches');
  expect(frame).toContain('System Diagnostics');
  expect(frame).toContain('Uninstall Everything');
  expect(frame).toContain('Gaming Mode');
  expect(frame).toContain('Exit');
});

test('renders section dividers', () => {
  const { lastFrame } = render(
    <MainMenu
      systemInfo={{ cpu: 'AMD', distro: 'Arch', bootloader: 'grub' }}
      onModuleSelect={() => {}}
      onGamingMode={() => {}}
      onExit={() => {}}
    />,
  );

  const frame = lastFrame();
  expect(frame).toContain('── SETUP ──');
  expect(frame).toContain('── OPTIMIZE ──');
  expect(frame).toContain('── TOOLS ──');
  expect(frame).toContain('── MODE ──');
});

test('renders system info line', () => {
  const { lastFrame } = render(
    <MainMenu
      systemInfo={{ cpu: 'Intel (GenuineIntel)', distro: 'Arch Linux', bootloader: 'limine' }}
      onModuleSelect={() => {}}
      onGamingMode={() => {}}
      onExit={() => {}}
    />,
  );

  const frame = lastFrame();
  expect(frame).toContain('CPU: Intel (GenuineIntel)');
  expect(frame).toContain('Distro: Arch Linux');
  expect(frame).toContain('Boot: limine');
});

test('renders badge indicators for all items', () => {
  const { lastFrame } = render(
    <MainMenu
      systemInfo={{ cpu: 'AMD', distro: 'Arch', bootloader: 'grub' }}
      onModuleSelect={() => {}}
      onGamingMode={() => {}}
      onExit={() => {}}
    />,
  );

  const frame = lastFrame();
  // Two-digit badges
  expect(frame).toContain(' 01 ');
  expect(frame).toContain(' 12 ');
  // Single-char badges with leading space
  expect(frame).toContain('\u23F5');  // Gaming Mode play icon
  expect(frame).toContain('\u2715');  // Exit X icon
});

test('first item is selected by default', () => {
  const { lastFrame } = render(
    <MainMenu
      systemInfo={{ cpu: 'AMD', distro: 'Arch', bootloader: 'grub' }}
      onModuleSelect={() => {}}
      onGamingMode={() => {}}
      onExit={() => {}}
    />,
  );

  const frame = lastFrame();
  // First item should have the selection indicator (▸)
  const lines = (frame || '').split('\n');
  const prereqLine = lines.find(l => l.includes('Prerequisites Check'));
  expect(prereqLine).toContain('\u25B8'); // ▸ arrow
});
