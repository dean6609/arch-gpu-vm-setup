import React, { useState, useEffect, useRef } from 'react';
import { Box, Text, useApp, useInput } from 'ink';
import { useWindowSize } from '../hooks/use-window-size.js';
import { COLORS as C } from '../utils/colors.js';
import path from 'node:path';
import { runScript } from '../utils/script-runner.js';
import { getScriptDir } from '../utils/system-detect.js';

// ── Line classification ───────────────────────────────────────────

type LineType =
  | 'section'    // "Checking XYZ..."
  | 'box-title'  // Box text title like "Prerequisites Check Summary"
  | 'result-ok'  // "Value: DETECTED"
  | 'result-err' // "Value: NOT DETECTED"
  | 'result-wrn' // "Value: caution"
  | 'table-head' // "PCI Address  Vendor..."
  | 'table-row'  // "0000:03:00.0  0x10de..."
  | 'summary'    // "Passed: 3 | Failed: 2"
  | 'separator'  // "────────────────"
  | 'body';      // everything else

function classifyLine(line: string): LineType {
  // Strip ANSI escape codes so we can match the raw text.
  const stripped = line.replace(/\x1b\[[0-9;]*m/g, '');
  const lower = stripped.toLowerCase();
  const trimmed = stripped.trim();

  // Box text: ╔═══╗ top, ║ Title ║ middle, ╚═══╝ bottom
  // These are produced by fmtr::box_text and should be skipped entirely
  if (/^[╔╗╚╝═]+/.test(trimmed)) {
    return 'separator';
  }
  if (trimmed.startsWith('║') && trimmed.endsWith('║')) {
    return 'box-title';
  }

  if (/^(checking|detecting|verifying|running|compiling|installing|downloading|configuring|building|removing|restoring|reverting|uninstalling|binding|unbinding|applying|cloning|attaching|switching|generating|creating|defining|enabling|injecting|setting up|step)\b/i.test(trimmed)) {
    return 'section';
  }
  // Noun-based section titles: "System Information", "CPU Information", etc.
  if (/^(system|cpu|memory|gpu|iommu|vfio|kernel|libvirt|user|diagnostics)\s+(information|status|parameters|groups|configuration|complete)\b/i.test(trimmed)) {
    return 'section';
  }
  if (/\b(NOT DETECTED|NOT FOUND|NOT ACCESSIBLE|NOT SUPPORTED|NOT A MEMBER|NOT RUNNING|NOT ENOUGH|NO .* DETECTED|NO .* FOUND|error|fail|failed|cannot|unable|fatal)\b/i.test(lower)) {
    return 'result-err';
  }
  if (/\b(warn|warning|caution|not recommended|may not|consider|less than)\b/i.test(lower)) {
    return 'result-wrn';
  }
  if (/\b(DETECTED|SUPPORTED|CONFIGURED|LOADED|ACTIVE|ENABLED|READY|INSTALLED|FOUND|EXCEEDS|OK)\b/i.test(lower)) {
    return 'result-ok';
  }
  if (/(PCI Address|Vendor|Device|Description|Driver)/i.test(trimmed) && /\s{2,}/.test(stripped)) {
    return 'table-head';
  }
  if (/\b(Passed|Failed|Skipped)\b.*\|/i.test(trimmed)) {
    return 'summary';
  }
  if (/\S+\s{2,}\S+/.test(trimmed) && trimmed.length > 20 && /\b(0x[0-9a-f]+|none)\b/i.test(lower)) {
    return 'table-row';
  }
  return 'body';
}

// ── Section matching helpers ──────────────────────────────────────

/**
 * Extract the subject noun from a section title.
 * E.g. "Checking RAM..." -> "ram", "Detecting GPUs..." -> "gpus"
 */
function extractSubject(title: string): string {
  const stripped = title.replace(/\x1b\[[0-9;]*m/g, '').trim();
  const match = stripped.match(
    /^(?:checking|detecting|verifying|running|compiling|installing|downloading|configuring|building)\s+(.+)$/i,
  );
  if (!match) return '';
  return match[1].replace(/\.+$/, '').trim().toLowerCase();
}

/**
 * Check whether a result line belongs to a section by keyword overlap.
 * Extracts significant words (>=3 chars) from the section subject and
 * checks if any of them appear in the line.  This redirects late-arriving
 * stderr lines (from fmtr::error) that were delivered after the next
 * section header was already opened.
 */
function lineBelongsToSection(line: string, subject: string): boolean {
  if (!subject) return false;
  const stripped = line.replace(/\x1b\[[0-9;]*m/g, '').trim().toLowerCase();
  // Match if any significant word from the subject appears in the line
  return subject.split(/\s+/).some(
    (w) => w.length >= 3 && stripped.includes(w),
  );
}

// ── Section card renderer ─────────────────────────────────────────

function SectionCard({
  title,
  lines,
  width,
}: {
  title: string;
  lines: string[];
  width: number;
}) {
  const inner = width - 4;

  return (
    <Box flexDirection="column" marginBottom={1}>
      {/* Section header */}
      <Box>
        <Text color={C.border}>{"\u250C"}</Text>
        <Text color={C.border}>{"\u2500".repeat(Math.max(1, inner))}</Text>
        <Text color={C.border}>{"\u2510"}</Text>
      </Box>
      <Box>
        <Text color={C.border}>{"\u2502"}</Text>
        <Text color={C.sectionTitle} bold>{` ${title}`}</Text>
        <Box flexGrow={1} />
        <Text color={C.border}>{"\u2502"}</Text>
      </Box>
      <Box>
        <Text color={C.border}>{"\u251C"}</Text>
        <Text color={C.border}>{"\u2500".repeat(Math.max(1, inner))}</Text>
        <Text color={C.border}>{"\u2524"}</Text>
      </Box>

      {/* Section body lines — classify once, filter and render in single pass */}
      {(() => {
        const rendered: React.ReactNode[] = [];
        for (const line of lines) {
          const type = classifyLine(line);
          if (type === 'box-title' || type === 'separator') continue;
          const i = rendered.length;

          if (type === 'table-head') {
            rendered.push(
              <Box key={i}>
                <Text color={C.border}>{"\u2502"}</Text>
                <Text> </Text>
                <Text color={C.info} bold>{line}</Text>
                <Box flexGrow={1} />
                <Text color={C.border}>{"\u2502"}</Text>
              </Box>
            );
          } else if (type === 'table-row') {
            rendered.push(
              <Box key={i}>
                <Text color={C.border}>{"\u2502"}</Text>
                <Text> </Text>
                <Text color={C.unselected}>{line}</Text>
                <Box flexGrow={1} />
                <Text color={C.border}>{"\u2502"}</Text>
              </Box>
            );
          } else if (type === 'summary') {
            rendered.push(
              <Box key={i}>
                <Text color={C.border}>{"\u2502"}</Text>
                <Text color={C.sectionTitle} bold>{` ${line}`}</Text>
                <Box flexGrow={1} />
                <Text color={C.border}>{"\u2502"}</Text>
              </Box>
            );
          } else {
            rendered.push(
              <Box key={i}>
                <Text color={C.border}>{"\u2502"}</Text>
                <Text> </Text>
                <Text
                  color={
                    type === 'result-err' ? C.error :
                    type === 'result-wrn' ? C.warning :
                    type === 'result-ok' ? C.success :
                    undefined
                  }
                  bold={type === 'result-err'}
                  dimColor={type === 'body'}
                >
                  {line.replace(/^ +/, '')}
                </Text>
                <Box flexGrow={1} />
                <Text color={C.border}>{"\u2502"}</Text>
              </Box>
            );
          }
        }
        return rendered;
      })()}

      {/* Footer */}
      <Box>
        <Text color={C.border}>{"\u2514"}</Text>
        <Text color={C.border}>{"\u2500".repeat(Math.max(1, inner))}</Text>
        <Text color={C.border}>{"\u2518"}</Text>
      </Box>
    </Box>
  );
}

// ── Main component ────────────────────────────────────────────────

interface ScriptRunnerProps {
  module: string;
  onBack: () => void;
}

const ScriptRunner: React.FC<ScriptRunnerProps> = ({ module, onBack }) => {
  const { exit } = useApp();
  const [output, setOutput] = useState<string[]>([]);
  const [isRunning, setIsRunning] = useState(true);
  const [exitCode, setExitCode] = useState<number | null>(null);
  const outputRef = useRef<string[]>([]);
  const { columns } = useWindowSize();

  const innerWidth = Math.max(15, columns - 4);

  const title = module
    .replace('.sh', '')
    .replace(/^\d+[_-]/, '')
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c: string) => c.toUpperCase());

  useEffect(() => {
    const scriptDir = getScriptDir();
    const scriptPath = path.join(scriptDir, 'scripts', 'modules', module);

    runScript(scriptPath, {
      cwd: scriptDir,
      onOutput: (data) => {
        const lines = data.split('\n').filter((l) => l !== '');
        for (const line of lines) {
          outputRef.current.push(line);
          if (outputRef.current.length > 150) {
            outputRef.current = outputRef.current.slice(-150);
          }
        }
        setOutput([...outputRef.current]);
      },
    }).then((result) => {
      setIsRunning(false);
      setExitCode(result.exitCode);
    });
  }, [module]);

  useInput((_input, key) => {
    if (key.escape) onBack();
    if (key.return && !isRunning) onBack();
  });

  // Group output into sections.
  //
  // Because fmtr::error() writes to stderr (unbuffered) while
  // fmtr::info/log/warn write to stdout (line-buffered), stderr lines
  // can arrive AFTER the next section's stdout header.  When that
  // happens the naive approach would attach the late line to the wrong
  // section.  We fix this by keyword-matching each non-section line
  // against previously-saved sections and redirecting it if there is a
  // subject-level word match.
  const sections: { title: string; lines: string[] }[] = [];
  let currentSection: { title: string; lines: string[] } | null = null;
  let orphanLines: string[] = [];
  let moduleTitle: string | null = null;

  for (const line of output) {
    const type = classifyLine(line);

    if (type === 'section') {
      // Flush orphan lines as "Output" section before the first real section
      if (orphanLines.length > 0 && sections.length === 0 && !currentSection) {
        sections.push({ title: 'Output', lines: orphanLines });
        orphanLines = [];
      }
      // Save previous section
      if (currentSection && currentSection.lines.length > 0) {
        sections.push(currentSection);
      }
      // Start new section using this line's text as the title
      currentSection = { title: line, lines: [] };
    } else if (type === 'box-title' && sections.length === 0 && !currentSection) {
      // Extract module title from the first box_text line before any section header.
      // Format: ║ Some Title ║ — extract the text between the ║ characters.
      if (moduleTitle === null) {
        const m = line.match(/║\s*(.+?)\s*║/);
        if (m) {
          moduleTitle = m[1];
        }
      }
    } else if ((type === 'box-title' || type === 'separator') && sections.length === 0 && !currentSection) {
      // Skip box-text and separator lines before any section (already handled above or decorative).
    } else if (currentSection) {
      // Check if this line belongs to a PREVIOUS section (handles
      // late-arriving stderr from fmtr::error that was written before
      // the current section header but delivered after).
      let placed = false;
      for (let i = sections.length - 1; i >= 0; i--) {
        const prevSubject = extractSubject(sections[i].title);
        if (lineBelongsToSection(line, prevSubject)) {
          sections[i].lines.push(line);
          placed = true;
          break;
        }
      }
      if (!placed) {
        currentSection.lines.push(line);
      }
    } else {
      // Buffer lines before any section header
      orphanLines.push(line);
    }
  }
  // Push last section
  if (currentSection && currentSection.lines.length > 0) {
    sections.push(currentSection);
  }
  // If no sections were ever found, put orphan lines into one "Output" section
  if (sections.length === 0 && orphanLines.length > 0) {
    sections.push({ title: 'Output', lines: orphanLines });
  }

  return (
    <Box flexDirection="column" paddingX={1} width="100%">
      {/* Module header */}
      <Box flexDirection="column" marginBottom={1}>
        <Box>
          <Text color={C.border}>{"\u250C"}</Text>
          <Text color={C.border}>{"\u2500".repeat(innerWidth)}</Text>
          <Text color={C.border}>{"\u2510"}</Text>
        </Box>
        <Box>
          <Text color={C.border}>{"\u2502"}</Text>
          <Box flexGrow={1} justifyContent="center">
            <Text color={C.title} bold>{` ${title} `}</Text>
          </Box>
          <Text color={C.border}>{"\u2502"}</Text>
        </Box>
        <Box>
          <Text color={C.border}>{"\u2514"}</Text>
          <Text color={C.border}>{"\u2500".repeat(innerWidth)}</Text>
          <Text color={C.border}>{"\u2518"}</Text>
        </Box>
      </Box>

      {/* Section cards */}
      <Box flexDirection="column" marginBottom={1}>
        {/* Extracted module title from box_text (shown outside any card) */}
        {moduleTitle !== null && (
          <Box marginBottom={1}>
            <Text color={C.sectionTitle} bold>{` ${moduleTitle}`}</Text>
          </Box>
        )}
        {sections.length === 0 ? (
          <Text dimColor>Running...</Text>
        ) : (
          sections
            // Skip sections that are empty after filtering, and sections
            // whose title is a box_text title (contains ║ or is "Output" with no real content).
            .filter((s) => {
              const t = classifyLine(s.title);
              if (t === 'box-title') return false;
              return s.lines.length > 0;
            })
            .map((section, i) => (
              <SectionCard
                key={`${i}-${section.title.slice(0, 20)}`}
                title={section.title}
                lines={section.lines}
                width={innerWidth + 4}
              />
            ))
        )}
      </Box>

      {/* Footer */}
      {isRunning ? (
        <Box justifyContent="center" width="100%">
          <Text>
            <Text color={C.dim}>Press </Text>
            <Text backgroundColor={C.footerBg} color={C.footerFg} bold>ESC</Text>
            <Text color={C.dim}> to go back</Text>
          </Text>
        </Box>
      ) : (
        <Box flexDirection="column">
          {exitCode !== 0 && (
            <Box flexDirection="column" marginBottom={1}>
              <Box>
                <Text color={C.border}>{"\u250C"}</Text>
                <Text color={C.border}>{"\u2500".repeat(innerWidth)}</Text>
                <Text color={C.border}>{"\u2510"}</Text>
              </Box>
              <Box>
                <Text color={C.border}>{"\u2502"}</Text>
                <Box flexGrow={1} justifyContent="center">
                  <Text color={C.error} bold>{` Failed (exit: ${exitCode}) `}</Text>
                </Box>
                <Text color={C.border}>{"\u2502"}</Text>
              </Box>
              <Box>
                <Text color={C.border}>{"\u2514"}</Text>
                <Text color={C.border}>{"\u2500".repeat(innerWidth)}</Text>
                <Text color={C.border}>{"\u2518"}</Text>
              </Box>
            </Box>
          )}
          <Box justifyContent="center" width="100%">
            <Text>
              <Text color={C.dim}>Press </Text>
              <Text backgroundColor={C.footerBg} color={C.footerFg} bold>Enter</Text>
              <Text color={C.dim}> or </Text>
              <Text backgroundColor={C.footerBg} color={C.footerFg} bold>ESC</Text>
              <Text color={C.dim}> to return to menu</Text>
            </Text>
          </Box>
        </Box>
      )}
    </Box>
  );
};

export default ScriptRunner;
