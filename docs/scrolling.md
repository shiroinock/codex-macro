# Scrolling the task grid

The top **8 × 10** keys show a window into the task catalog. Projects are rows and tasks are columns. The catalog is no longer truncated at ten projects or ten tasks. Offscreen tasks keep receiving status updates and layer attention indicators include them.

The bottom two rows are utilities (positions below are one-based):

| Physical row | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 9 | Select row 1 | Select row 2 | Select row 3 | Select row 4 | Select row 5 | Select row 6 | Select row 7 | Select row 8 | ↑ | — |
| 10 | Codex | herdr | Claude CLI | Claude Desktop | — | — | — | ← | ↓ | → |

- **↑ / ↓** moves the project window by one row. Projectless chats are the final logical group and scroll with the other rows.
- Select one of the eight row buttons, then **← / →** moves only that project's task window by one task. Other project rows keep their positions.
- A bright cyan row button marks the selected visible row. Arrow keys are bright when movement is possible and dim at the boundary. These are RGB indicators on physical keys, not printed arrow legends.
- Each project remembers its horizontal offset while scrolling vertically. Each source layer keeps its own viewport. Restarting the daemon resets scroll offsets.
- Positions clamp when tasks/projects disappear. Selecting or scrolling utilities never navigates to a task. Pressing a task key opens exactly the task currently displayed there; acknowledging a completed task also uses that mapping.

Example: a project with 14 tasks initially shows tasks 1–10. Select its row and press → four times to see tasks 5–14. The leftmost and rightmost task keys now open tasks 5 and 14.

CLI equivalents, also accepting `--config PATH`:

```sh
c100-status focus-row 3
c100-status scroll right
c100-status scroll down
c100-status inspect
```

`inspect` includes `topRow`, `selectedRow`, per-project `columnOffsets`, logical `projectRows`, and a `visible` list mapping physical key indexes to session IDs. These fields use zero-based indexes. The `catalog` command lists the complete logical catalog; its row/column coordinates are not physical keys after scrolling.

## Validation

Release build and the full self-test suite pass. A 12-project × 14-task fixture exercises the complete logical layout and viewport: no truncation, unique physical key mapping, offscreen completion retention, independent project offsets, boundaries, and utility-row isolation. On the connected device, vertical scrolling reached all 20 current tasks across 11 logical rows and stopped at the expected boundary. Live layer-retention assertions were interrupted by concurrent physical key input; the service remains installed and running with the new controls.
