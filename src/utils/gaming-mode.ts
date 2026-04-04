import fs from 'node:fs';
import path from 'node:path';
import { readConfig, writeConfig } from './config.js';
import { execa } from 'execa';

export interface GamingModeConfig {
  user: string;
  vmName: string;
  gpuPci: string;
  gpuAudioPci: string;
  gpuOriginalDriver: string;
  gpuAudioOriginalDriver: string;
  igpuPci: string;
  igpuAudioPci: string;
  drmDgpu: string;
  drmIgpu: string;
  monitorDgpu: string;
  monitorIgpu: string;
  resolution: string;
  hzDgpu: string;
  hzIgpu: string;
  uwsmEnv: string;
  monitorsConf: string;
}

const DEFAULTS: Partial<GamingModeConfig> = {
  vmName: 'WindowsVM',
  resolution: '1920x1080',
  hzDgpu: '240',
  hzIgpu: '60',
  gpuOriginalDriver: 'amdgpu',
  gpuAudioOriginalDriver: 'snd_hda_intel',
};

export function getGamingModeConfPath(scriptDir: string): string {
  return path.join(scriptDir, 'gaming-mode.conf');
}

export function readGamingModeConf(
  scriptDir: string,
): Partial<GamingModeConfig> {
  const confPath = getGamingModeConfPath(scriptDir);
  const raw = readConfig(confPath);

  // Map GM_ prefixed keys to camelCase
  const config: Partial<GamingModeConfig> = {};
  const keyMap: Record<string, keyof GamingModeConfig> = {
    GM_USER: 'user',
    GM_VM_NAME: 'vmName',
    GM_GPU_PCI: 'gpuPci',
    GM_GPU_AUDIO_PCI: 'gpuAudioPci',
    GM_GPU_ORIGINAL_DRIVER: 'gpuOriginalDriver',
    GM_GPU_AUDIO_ORIGINAL_DRIVER: 'gpuAudioOriginalDriver',
    GM_IGPU_PCI: 'igpuPci',
    GM_IGPU_AUDIO_PCI: 'igpuAudioPci',
    GM_DRM_DGPU: 'drmDgpu',
    GM_DRM_IGPU: 'drmIgpu',
    GM_MONITOR_DGPU: 'monitorDgpu',
    GM_MONITOR_IGPU: 'monitorIgpu',
    GM_RESOLUTION: 'resolution',
    GM_HZ_DGPU: 'hzDgpu',
    GM_HZ_IGPU: 'hzIgpu',
    GM_UWSM_ENV: 'uwsmEnv',
    GM_MONITORS_CONF: 'monitorsConf',
  };

  for (const [envKey, configKey] of Object.entries(keyMap)) {
    if (raw[envKey]) {
      config[configKey] = raw[envKey];
    }
  }

  return config;
}

export function writeGamingModeConf(
  scriptDir: string,
  config: Partial<GamingModeConfig>,
): void {
  const confPath = getGamingModeConfPath(scriptDir);

  // Map camelCase back to GM_ prefixed keys
  const raw: Record<string, string> = {};
  const keyMap: Record<keyof GamingModeConfig, string> = {
    user: 'GM_USER',
    vmName: 'GM_VM_NAME',
    gpuPci: 'GM_GPU_PCI',
    gpuAudioPci: 'GM_GPU_AUDIO_PCI',
    gpuOriginalDriver: 'GM_GPU_ORIGINAL_DRIVER',
    gpuAudioOriginalDriver: 'GM_GPU_AUDIO_ORIGINAL_DRIVER',
    igpuPci: 'GM_IGPU_PCI',
    igpuAudioPci: 'GM_IGPU_AUDIO_PCI',
    drmDgpu: 'GM_DRM_DGPU',
    drmIgpu: 'GM_DRM_IGPU',
    monitorDgpu: 'GM_MONITOR_DGPU',
    monitorIgpu: 'GM_MONITOR_IGPU',
    resolution: 'GM_RESOLUTION',
    hzDgpu: 'GM_HZ_DGPU',
    hzIgpu: 'GM_HZ_IGPU',
    uwsmEnv: 'GM_UWSM_ENV',
    monitorsConf: 'GM_MONITORS_CONF',
  };

  for (const [configKey, envKey] of Object.entries(keyMap)) {
    const value = config[configKey as keyof GamingModeConfig];
    if (value) {
      raw[envKey] = value;
    }
  }

  writeConfig(
    confPath,
    raw,
    `# Gaming Mode Configuration\n# Generated: ${new Date().toISOString()}\n# Re-run gaming-mode-setup.sh to reconfigure`,
  );
}

// ── Gaming Mode State ─────────────────────────────────────────

const STATE_DIR = '/tmp/gaming-mode';

export function getGamingModeState(): string {
  try {
    const statePath = path.join(STATE_DIR, 'state');
    if (fs.existsSync(statePath)) {
      return fs.readFileSync(statePath, 'utf-8').trim();
    }
  } catch {
    // ignore
  }
  return 'unknown';
}

export async function isDaemonRunning(): Promise<boolean> {
  try {
    const user = process.env.USER || '';
    await execa('systemctl', ['--user', 'is-active', 'gaming-mode-daemon.service']);
    return true;
  } catch {
    return false;
  }
}

export async function getVmState(vmName: string): Promise<string> {
  try {
    const { stdout } = await execa('virsh', ['domstate', vmName]);
    return stdout.split('\n')[0].trim();
  } catch {
    return 'unknown';
  }
}

export function getDaemonLog(): string {
  try {
    const logPath = path.join(STATE_DIR, 'log');
    if (fs.existsSync(logPath)) {
      const content = fs.readFileSync(logPath, 'utf-8');
      const lines = content.split('\n');
      return lines.slice(-10).join('\n');
    }
  } catch {
    // ignore
  }
  return '';
}

export function getCurrentGpuDriver(pci: string): string {
  try {
    const link = `/sys/bus/pci/devices/${pci}/driver`;
    if (fs.existsSync(link)) {
      const target = fs.readlinkSync(link);
      return target.split('/').pop() || 'none';
    }
  } catch {
    // ignore
  }
  return 'none';
}
