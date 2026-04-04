import { execa } from 'execa';
import path from 'node:path';

export interface ScriptResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

/**
 * Executes a bash script from the scripts/ directory.
 * Streams output through callbacks while also capturing it.
 */
export async function runScript(
  scriptPath: string,
  options: {
    args?: string[];
    cwd?: string;
    onOutput?: (data: string) => void;
    sudo?: boolean;
  } = {},
): Promise<ScriptResult> {
  const {
    args = [],
    cwd = process.cwd(),
    onOutput,
    sudo = false,
  } = options;

  const absPath = path.resolve(scriptPath);

  const cmd = sudo ? 'sudo' : absPath;
  const cmdArgs = sudo ? [absPath, ...args] : args;

  let stdout = '';
  let stderr = '';

  try {
    const proc = execa(cmd, cmdArgs, {
      cwd,
      env: {
        ...process.env,
        SCRIPT_DIR: cwd,
      },
      reject: false,
    });

    // Stream stdout
    proc.stdout?.on('data', (data: Buffer) => {
      const text = data.toString();
      stdout += text;
      onOutput?.(text);
    });

    // Stream stderr
    proc.stderr?.on('data', (data: Buffer) => {
      const text = data.toString();
      stderr += text;
      onOutput?.(text);
    });

    const { exitCode } = await proc;

    return {
      exitCode: exitCode ?? 1,
      stdout,
      stderr,
    };
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    return { exitCode: 1, stdout, stderr: stderr + '\n' + msg };
  }
}

/**
 * Executes a bash script and returns a cleanup function to kill it.
 * Useful for long-running processes like the gaming mode daemon.
 */
export function runScriptStream(
  scriptPath: string,
  options: {
    args?: string[];
    cwd?: string;
    onOutput?: (data: string) => void;
    sudo?: boolean;
  } = {},
) {
  const {
    args = [],
    cwd = process.cwd(),
    onOutput,
    sudo = false,
  } = options;

  const absPath = path.resolve(scriptPath);
  const cmd = sudo ? 'sudo' : absPath;
  const cmdArgs = sudo ? [absPath, ...args] : args;

  let stdout = '';
  let stderr = '';

  const proc = execa(cmd, cmdArgs, {
    cwd,
    env: {
      ...process.env,
      SCRIPT_DIR: cwd,
    },
    reject: false,
  });

  proc.stdout?.on('data', (data: Buffer) => {
    const text = data.toString();
    stdout += text;
    onOutput?.(text);
  });

  proc.stderr?.on('data', (data: Buffer) => {
    const text = data.toString();
    stderr += text;
    onOutput?.(text);
  });

  return {
    proc,
    kill: () => proc.kill(),
    getOutput: () => ({ stdout, stderr }),
  };
}

/**
 * Runs a module script and returns the result.
 */
export async function runModule(
  moduleName: string,
  options: {
    args?: string[];
    onOutput?: (data: string) => void;
  } = {},
): Promise<ScriptResult> {
  const scriptDir = process.env.SCRIPT_DIR || process.cwd();
  const scriptPath = path.join(scriptDir, 'scripts', 'modules', moduleName);
  return runScript(scriptPath, { ...options, cwd: scriptDir });
}

/**
 * Sources utils.sh and runs a detection function from it.
 */
export async function runBashDetection(
  funcName: string,
): Promise<string | null> {
  const scriptDir = process.env.SCRIPT_DIR || process.cwd();
  const utilsPath = path.join(scriptDir, 'scripts', 'utils.sh');

  try {
    const { stdout } = await execa('bash', [
      '-c',
      `source "${utilsPath}" && ${funcName}`,
    ]);
    return stdout.trim() || null;
  } catch {
    return null;
  }
}
