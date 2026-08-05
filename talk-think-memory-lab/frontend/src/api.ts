import type {
  Capabilities, MemoryRecord, MemoryStatus, ServiceStatus, SpeechTranscription,
} from './types';

const publicBase = '/lab';

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: { 'Content-Type': 'application/json', ...init?.headers },
  });
  if (!response.ok) {
    const body = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(body?.error?.detail ?? body?.detail?.detail ?? body?.detail ?? response.statusText);
  }
  return response.json() as Promise<T>;
}

const base = (space: string) => `${publicBase}/api/v1/spaces/${encodeURIComponent(space)}/memories`;

async function transcribe(space: string, file: File): Promise<SpeechTranscription> {
  const response = await fetch(
    `${publicBase}/api/v1/spaces/${encodeURIComponent(space)}/speech/asr`,
    {
      method: 'POST',
      headers: { 'Content-Type': file.type || 'application/octet-stream' },
      body: file,
    },
  );
  if (!response.ok) {
    const body = await response.json().catch(() => ({ detail: response.statusText }));
    throw new Error(body?.detail?.detail ?? body?.detail ?? response.statusText);
  }
  return response.json() as Promise<SpeechTranscription>;
}

export const api = {
  list: async (space: string, includeRemoved = true) =>
    request<{ items: MemoryRecord[]; total: number }>(`${base(space)}?include_removed=${includeRemoved}`),
  create: async (space: string, title: string, content: string) =>
    request<MemoryRecord>(base(space), { method: 'POST', body: JSON.stringify({ title, content }) }),
  update: async (record: MemoryRecord, title: string, content: string) =>
    request<MemoryRecord>(`${base(record.memory_space)}/${record.id}`, {
      method: 'PATCH',
      body: JSON.stringify({ title, content, expected_version: record.version }),
    }),
  transition: async (record: MemoryRecord, target_status: MemoryStatus) =>
    request<MemoryRecord>(`${base(record.memory_space)}/${record.id}/transitions`, {
      method: 'POST',
      body: JSON.stringify({ target_status, expected_version: record.version }),
    }),
  trash: async (record: MemoryRecord) =>
    request<MemoryRecord>(`${base(record.memory_space)}/${record.id}?expected_version=${record.version}`, {
      method: 'DELETE',
    }),
  purge: async (record: MemoryRecord) =>
    request(`${base(record.memory_space)}/${record.id}/purge`, {
      method: 'POST',
      body: JSON.stringify({
        expected_version: record.version,
        confirm_memory_id: record.id,
        confirm_irreversible: true,
        reason: 'operator confirmed permanent deletion from Memory Studio',
      }),
    }),
  status: async () => request<ServiceStatus>(`${publicBase}/status`),
  capabilities: async () => request<Capabilities>(`${publicBase}/api/v1/capabilities`),
  transcribe,
};
