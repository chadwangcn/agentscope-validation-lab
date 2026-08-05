export type MemoryStatus = 'draft' | 'review' | 'published' | 'withdrawn' | 'trashed' | 'purged';

export interface MemoryRecord {
  memory_space: string;
  id: string;
  title: string;
  content: string;
  status: MemoryStatus;
  metadata: Record<string, unknown>;
  version: number;
  created_at: string;
  updated_at: string;
}

export interface ServiceStatus {
  status: string;
  service_version: string;
  packages: Record<string, string | null>;
  reme: { reachable: boolean; [key: string]: unknown };
  neo4j: { reachable: boolean; [key: string]: unknown };
  capabilities: Capabilities;
}

export interface CapabilityStatus {
  status: 'validated' | 'not_configured';
  provider?: string | null;
  transport?: string | null;
  validated_at?: string | null;
}

export interface Capabilities {
  chat: CapabilityStatus;
  asr: CapabilityStatus;
  tts: CapabilityStatus;
  embedding: CapabilityStatus;
}

export interface SpeechTranscription {
  memory_space: string;
  provider: 'volcengine_speech';
  capability: 'asr';
  transcript: string;
  duration_ms: number | null;
  request_id: string;
}
