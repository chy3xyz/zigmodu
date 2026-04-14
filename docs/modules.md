# Module Documentation

## Module Dependency Graph

```mermaid
graph TD
    order[order] --> inventory, 
    inventory[inventory] --> 
    payment[payment] --> order, 
```

## Module Details

### order

Order management

**Dependencies:** inventory 

### inventory

Inventory tracking

**Dependencies:** None

### payment

Payment processing

**Dependencies:** order 

