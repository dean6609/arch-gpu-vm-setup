import { useState, useEffect } from 'react';

interface WindowSize {
  columns: number;
  rows: number;
}

/**
 * Custom hook that tracks terminal dimensions by listening to stdout resize events.
 * Ink 5 does not export useWindowSize, so we implement it ourselves.
 */
export function useWindowSize(): WindowSize {
  const [size, setSize] = useState<WindowSize>(() => ({
    columns: process.stdout.columns || 80,
    rows: process.stdout.rows || 24,
  }));

  useEffect(() => {
    const onResize = () => {
      setSize({
        columns: process.stdout.columns || 80,
        rows: process.stdout.rows || 24,
      });
    };

    process.stdout.on('resize', onResize);
    return () => {
      process.stdout.off('resize', onResize);
    };
  }, []);

  return size;
}
