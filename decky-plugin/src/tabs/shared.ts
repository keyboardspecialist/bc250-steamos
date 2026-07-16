import type { Snapshot } from "../types";

export interface Confirmation {
  title: string;
  description: string;
  destructive?: boolean;
}

export type MutationRunner = (
  label: string,
  operation: () => Promise<void>,
  confirmation?: Confirmation,
) => void;

export interface TabProps {
  snapshot: Snapshot;
  busy: boolean;
  runMutation: MutationRunner;
}
