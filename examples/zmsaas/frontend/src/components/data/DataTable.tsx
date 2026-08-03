import { For, Show, type JSX } from 'solid-js';
import { Button } from '@/components/ui/button';

export type ColumnDef<T> = {
  key: string;
  header: string;
  render?: (row: T) => JSX.Element;
};

type DataTableProps<T> = {
  columns: ColumnDef<T>[];
  rows: T[];
  total: number;
  page: number;
  pageSize: number;
  onPageChange: (page: number) => void;
  loading?: boolean;
  rowKey: (row: T) => string | number;
  onEdit?: (row: T) => void;
  onDelete?: (row: T) => void;
  emptyText?: string;
};

function cell<T>(row: T, col: ColumnDef<T>): JSX.Element {
  if (col.render) return col.render(row);
  const value = (row as Record<string, unknown>)[col.key];
  return value === undefined || value === null ? '—' : String(value);
}

export function DataTable<T>(props: DataTableProps<T>) {
  const pageCount = () => Math.max(1, Math.ceil(props.total / props.pageSize));
  return (
    <div class="space-y-3">
      <div class="overflow-hidden rounded-lg border bg-card">
        <table class="w-full text-sm">
          <thead class="bg-muted/50 text-muted-foreground">
            <tr>
              <For each={props.columns}>
                {(col) => <th class="px-4 py-2.5 text-left font-medium">{col.header}</th>}
              </For>
              <Show when={props.onEdit || props.onDelete}>
                <th class="px-4 py-2.5 text-right font-medium">Actions</th>
              </Show>
            </tr>
          </thead>
          <tbody>
            <Show
              when={props.rows.length > 0}
              fallback={(
                <tr>
                  <td
                    colSpan={props.columns.length + (props.onEdit || props.onDelete ? 1 : 0)}
                    class="px-4 py-10 text-center text-muted-foreground"
                  >
                    {props.emptyText ?? 'No records'}
                  </td>
                </tr>
              )}
            >
              <For each={props.rows}>
                {(row) => (
                  <tr class="border-t first:border-t-0 hover:bg-muted/30">
                    <For each={props.columns}>
                      {(col) => <td class="px-4 py-2.5">{cell(row, col)}</td>}
                    </For>
                    <Show when={props.onEdit || props.onDelete}>
                      <td class="px-4 py-2.5 text-right">
                        <div class="flex justify-end gap-2">
                          <Show when={props.onEdit}>
                            <Button size="sm" variant="outline" onClick={() => props.onEdit?.(row)}>
                              Edit
                            </Button>
                          </Show>
                          <Show when={props.onDelete}>
                            <Button size="sm" variant="destructive" onClick={() => props.onDelete?.(row)}>
                              Delete
                            </Button>
                          </Show>
                        </div>
                      </td>
                    </Show>
                  </tr>
                )}
              </For>
            </Show>
          </tbody>
        </table>
      </div>
      <div class="flex items-center justify-between text-sm text-muted-foreground">
        <span>{props.total} total</span>
        <div class="flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            disabled={props.page <= 1 || props.loading}
            onClick={() => props.onPageChange(props.page - 1)}
          >
            Prev
          </Button>
          <span>Page {props.page} / {pageCount()}</span>
          <Button
            size="sm"
            variant="outline"
            disabled={props.page >= pageCount() || props.loading}
            onClick={() => props.onPageChange(props.page + 1)}
          >
            Next
          </Button>
        </div>
      </div>
    </div>
  );
}
