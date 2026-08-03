// Orders entity + UI field schema shared by DataTable / EntityForm so a
// generated CRUD screen is data-driven instead of hand-rolled per module.

export type OrderStatus = 'pending' | 'paid' | 'cancelled';

export type Order = {
  id: number;
  org_id: number;
  customer: string;
  amount: number; // 分 (cents)
  status: OrderStatus;
  notes: string;
  created_at: number;
  updated_at: number;
};

export type OrderField = {
  name: string;
  label: string;
  type: 'text' | 'number' | 'textarea' | 'select';
  required?: boolean;
  options?: { value: string; label: string }[];
  placeholder?: string;
};

export const orderFields: OrderField[] = [
  { name: 'customer', label: 'Customer', type: 'text', required: true, placeholder: 'Acme Inc.' },
  { name: 'amount', label: 'Amount (分)', type: 'number', required: true, placeholder: '9900' },
  {
    name: 'status',
    label: 'Status',
    type: 'select',
    required: true,
    options: [
      { value: 'pending', label: 'Pending' },
      { value: 'paid', label: 'Paid' },
      { value: 'cancelled', label: 'Cancelled' },
    ],
  },
  { name: 'notes', label: 'Notes', type: 'textarea', placeholder: 'Optional…' },
];
