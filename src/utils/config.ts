import fs from 'node:fs';
import path from 'node:path';

/**
 * Reads a bash-style config file (KEY="value") and returns a Record.
 * Handles quoted values, comments, and empty lines.
 */
export function readConfig(filePath: string): Record<string, string> {
  const config: Record<string, string> = {};

  if (!fs.existsSync(filePath)) {
    return config;
  }

  const content = fs.readFileSync(filePath, 'utf-8');

  for (const line of content.split('\n')) {
    const trimmed = line.trim();

    // Skip empty lines and comments
    if (!trimmed || trimmed.startsWith('#')) {
      continue;
    }

    // Parse KEY="value" or KEY=value
    const match = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!match) {
      continue;
    }

    const [, key, rawValue] = match;
    // Remove surrounding quotes if present
    let value = rawValue.trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    config[key] = value;
  }

  return config;
}

/**
 * Writes a Record<string, string> to a bash-style config file.
 * Adds a header comment with generation timestamp.
 */
export function writeConfig(
  filePath: string,
  config: Record<string, string>,
  header?: string,
): void {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }

  const lines: string[] = [];

  if (header) {
    lines.push(header);
  } else {
    lines.push(`# Configuration file`);
    lines.push(`# Generated: ${new Date().toISOString()}`);
  }

  lines.push('');

  for (const [key, value] of Object.entries(config)) {
    // Always quote values to be safe with bash sourcing
    lines.push(`${key}="${value}"`);
  }

  fs.writeFileSync(filePath, lines.join('\n') + '\n', 'utf-8');
}

/**
 * Ensures a config file exists, optionally with default values.
 */
export function ensureConfig(
  filePath: string,
  defaults: Record<string, string> = {},
  header?: string,
): Record<string, string> {
  if (fs.existsSync(filePath)) {
    return readConfig(filePath);
  }

  if (Object.keys(defaults).length > 0) {
    writeConfig(filePath, defaults, header);
  }

  return defaults;
}
