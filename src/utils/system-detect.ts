import { execa } from 'execa';
import fs from 'node:fs';

// ── CPU Detection ──────────────────────────────────────────────

export interface CpuInfo {
  vendor: string;
  vendorId: string;
  virtualization: string;
}

export async function detectCpu(): Promise<CpuInfo> {
  try {
    const { stdout } = await execa('awk', [
      '-F:',
      '/vendor_id/ {print $2; exit}',
      '/proc/cpuinfo',
    ]);

    const vendorId = stdout.trim();

    let vendor: string;
    let virtualization: string;

    if (vendorId.includes('AuthenticAMD')) {
      vendor = 'AMD';
      virtualization = 'svm';
    } else if (vendorId.includes('GenuineIntel')) {
      vendor = 'Intel';
      virtualization = 'vmx';
    } else {
      vendor = 'Unknown';
      virtualization = 'unknown';
    }

    return { vendor, vendorId, virtualization };
  } catch {
    return { vendor: 'Unknown', vendorId: '', virtualization: 'unknown' };
  }
}

// ── GPU Detection ──────────────────────────────────────────────

export interface GpuInfo {
  pci: string;
  vendor: string;
  device: string;
  description: string;
  driver: string;
  type: 'integrated' | 'dedicated' | 'unknown';
}

const INTEGRATED_VENDORS = ['0x1002', '0x8086'];

export async function detectGpus(): Promise<GpuInfo[]> {
  const gpus: GpuInfo[] = [];

  try {
    // Get all PCI devices with class 03xx (display controllers)
    const { stdout: lspciOutput } = await execa('lspci', ['-D']);

    for (const line of lspciOutput.split('\n')) {
      if (!line) continue;

      const pciMatch = line.match(/^([0-9a-fA-F:]+)\s+(.*)$/);
      if (!pciMatch) continue;

      const pci = pciMatch[1];
      const desc = pciMatch[2];

      // Check if it's a display device
      if (!desc.match(/03[0-9a-f]{2}/)) continue;

      // Read vendor and device IDs
      let vendor = '';
      let device = '';
      const vendorPath = `/sys/bus/pci/devices/${pci}/vendor`;
      const devicePath = `/sys/bus/pci/devices/${pci}/device`;

      if (fs.existsSync(vendorPath)) {
        vendor = fs.readFileSync(vendorPath, 'utf-8').trim();
      }
      if (fs.existsSync(devicePath)) {
        device = fs.readFileSync(devicePath, 'utf-8').trim();
      }

      // Get current driver
      let driver = 'none';
      const driverLink = `/sys/bus/pci/devices/${pci}/driver`;
      if (fs.existsSync(driverLink)) {
        try {
          const target = fs.readlinkSync(driverLink);
          driver = target.split('/').pop() || 'unknown';
        } catch {
          driver = 'unknown';
        }
      }

      // Determine type
      const type: GpuInfo['type'] = INTEGRATED_VENDORS.includes(vendor)
        ? 'integrated'
        : 'dedicated';

      gpus.push({ pci, vendor, device, description: desc, driver, type });
    }
  } catch {
    // lspci not available
  }

  return gpus;
}

// ── IOMMU Detection ────────────────────────────────────────────

export async function detectIommuGroups(): Promise<number> {
  try {
    const iommuPath = '/sys/kernel/iommu_groups';
    if (!fs.existsSync(iommuPath)) {
      return 0;
    }

    const entries = fs.readdirSync(iommuPath);
    return entries.filter((e: string) => /^\d+$/.test(e)).length;
  } catch {
    return 0;
  }
}

export async function getIommuGroup(pci: string): Promise<string | null> {
  try {
    const link = `/sys/bus/pci/devices/${pci}/iommu_group`;
    if (!fs.existsSync(link)) return null;
    const target = fs.readlinkSync(link);
    return target.split('/').pop() || null;
  } catch {
    return null;
  }
}

// ── Bootloader Detection ──────────────────────────────────────

export type BootloaderType = 'grub' | 'limine' | 'systemd-boot' | 'unknown';

export async function detectBootloader(): Promise<{
  type: BootloaderType;
  config: string;
}> {
  if (fs.existsSync('/etc/default/limine')) {
    return { type: 'limine', config: '/etc/default/limine' };
  }

  if (fs.existsSync('/etc/default/grub')) {
    return { type: 'grub', config: '/etc/default/grub' };
  }

  const bootDirs = [
    '/boot/loader/entries',
    '/boot/efi/loader/entries',
    '/efi/loader/entries',
  ];

  for (const dir of bootDirs) {
    if (fs.existsSync(dir)) {
      try {
        const entries = fs
          .readdirSync(dir)
          .filter((f: string) => f.endsWith('.conf') && !f.endsWith('-fallback.conf'));
        if (entries.length > 0) {
          return {
            type: 'systemd-boot',
            config: `${dir}/${entries[0]}`,
          };
        }
      } catch {
        // ignore
      }
    }
  }

  return { type: 'unknown', config: '' };
}

// ── Memory Info ────────────────────────────────────────────────

export async function getMemoryInfo(): Promise<{
  totalGb: number;
  availableGb: number;
}> {
  try {
    const meminfo = fs.readFileSync('/proc/meminfo', 'utf-8');
    const totalKb = parseInt(
      meminfo.match(/MemTotal:\s+(\d+)/)?.[1] || '0',
      10,
    );
    const availKb = parseInt(
      meminfo.match(/MemAvailable:\s+(\d+)/)?.[1] || '0',
      10,
    );
    return {
      totalGb: Math.round(totalKb / 1024 / 1024),
      availableGb: Math.round(availKb / 1024 / 1024),
    };
  } catch {
    return { totalGb: 0, availableGb: 0 };
  }
}

// ── Kernel Info ────────────────────────────────────────────────

export async function getKernelInfo(): Promise<{
  kernel: string;
  isZen: boolean;
  cmdline: string;
}> {
  try {
    const { stdout: uname } = await execa('uname', ['-r']);
    const cmdline = fs.readFileSync('/proc/cmdline', 'utf-8');
    return {
      kernel: uname.trim(),
      isZen: uname.includes('zen'),
      cmdline,
    };
  } catch {
    return { kernel: 'unknown', isZen: false, cmdline: '' };
  }
}

// ── Monitor Detection (Hyprland) ──────────────────────────────

export interface MonitorInfo {
  name: string;
  width: number;
  height: number;
  refreshRate: number;
  description: string;
}

export async function detectMonitors(): Promise<MonitorInfo[]> {
  try {
    const { stdout } = await execa('hyprctl', ['monitors', '-j']);
    const monitors = JSON.parse(stdout);

    return monitors.map((m: Record<string, unknown>) => ({
      name: m.name as string,
      width: m.width as number,
      height: m.height as number,
      refreshRate:
        typeof m.refreshRate === 'number'
          ? m.refreshRate
          : parseFloat(String(m.refreshRate || 0)),
      description: (m.description as string) || '',
    }));
  } catch {
    return [];
  }
}

// ── VM Detection ──────────────────────────────────────────────

export async function detectVMs(): Promise<string[]> {
  try {
    const { stdout } = await execa('virsh', ['list', '--all', '--name']);
    return stdout
      .split('\n')
      .map((s: string) => s.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

// ── User Info ─────────────────────────────────────────────────

export function getCurrentUser(): string {
  return process.env.USER || process.env.USERNAME || 'root';
}

export function getScriptDir(): string {
  // The directory where the bash scripts live
  return process.env.SCRIPT_DIR || process.cwd();
}
