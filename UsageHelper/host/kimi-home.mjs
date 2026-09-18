import { homedir } from 'node:os';
import { join } from 'node:path';

// macOS host only; mirrors Orca getHostKimiHome without loading Windows process probes.
export function getHostKimiHome() {
  return process.env.KIMI_CODE_HOME?.trim() || join(homedir(), '.kimi-code');
}
