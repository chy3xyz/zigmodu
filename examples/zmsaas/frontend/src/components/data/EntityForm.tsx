import { For, Show, createSignal } from 'solid-js';
import { Button } from '@/components/ui/button';

export type FieldDef = {
  name: string;
  label: string;
  type: 'text' | 'number' | 'textarea' | 'select';
  required?: boolean;
  options?: { value: string; label: string }[];
  placeholder?: string;
};

type EntityFormProps = {
  fields: FieldDef[];
  initial?: Record<string, unknown>;
  submitLabel: string;
  onSubmit: (values: Record<string, string>) => Promise<void> | void;
  onCancel?: () => void;
};

function toInputValue(value: unknown): string {
  if (value === undefined || value === null) return '';
  return String(value);
}

export function EntityForm(props: EntityFormProps) {
  const [values, setValues] = createSignal<Record<string, string>>(
    Object.fromEntries(props.fields.map((f) => [f.name, toInputValue(props.initial?.[f.name])])),
  );
  const [error, setError] = createSignal<string | null>(null);
  const [submitting, setSubmitting] = createSignal(false);

  function setField(name: string, value: string) {
    setValues((prev) => ({ ...prev, [name]: value }));
  }

  async function submit(e: Event) {
    e.preventDefault();
    const data = values();
    for (const f of props.fields) {
      if (f.required && !data[f.name]?.trim()) {
        setError(`${f.label} is required`);
        return;
      }
    }
    setError(null);
    setSubmitting(true);
    try {
      await props.onSubmit(data);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Submit failed');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={submit} class="space-y-4">
      <For each={props.fields}>
        {(field) => (
          <label class="block text-sm font-medium">
            {field.label}
            {field.required && <span class="text-destructive"> *</span>}
            <Show
              when={field.type === 'select'}
              fallback={(
                <Show
                  when={field.type === 'textarea'}
                  fallback={(
                    <input
                      type={field.type === 'number' ? 'number' : 'text'}
                      value={values()[field.name] ?? ''}
                      placeholder={field.placeholder}
                      required={field.required}
                      onInput={(e) => setField(field.name, e.currentTarget.value)}
                      class="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                    />
                  )}
                >
                  <textarea
                    value={values()[field.name] ?? ''}
                    placeholder={field.placeholder}
                    rows={3}
                    onInput={(e) => setField(field.name, e.currentTarget.value)}
                    class="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
                  />
                </Show>
              )}
            >
              <select
                value={values()[field.name] ?? ''}
                onChange={(e) => setField(field.name, e.currentTarget.value)}
                class="mt-1 w-full rounded-md border bg-background px-3 py-2 text-sm"
              >
                <option value="">—</option>
                <For each={field.options ?? []}>
                  {(opt) => <option value={opt.value}>{opt.label}</option>}
                </For>
              </select>
            </Show>
          </label>
        )}
      </For>
      <Show when={error()}>
        <p class="text-sm text-destructive">{error()}</p>
      </Show>
      <div class="flex justify-end gap-2">
        <Show when={props.onCancel}>
          <Button type="button" variant="outline" onClick={props.onCancel}>
            Cancel
          </Button>
        </Show>
        <Button type="submit" disabled={submitting()}>
          {props.submitLabel}
        </Button>
      </div>
    </form>
  );
}
