# SuperTerm behavior contract manifest

This manifest freezes the user-visible and externally observable contracts
owned by the test suite. A refactor may change implementation, timing, or ANSI
spelling only where the named suite permits it; it must not edit an expectation
to make a behavior change look like a migration success.

Each `*_test.py` suite appears exactly once. `contract_manifest_test.py`
enforces the mapping and the required coverage areas.

| Suite | Area | Frozen contract |
| --- | --- | --- |
| alwaysserver_test.py | sessions, lifecycle | Every configured session starts with a daemon and detach/exit preserve the documented lifetime. |
| appcursor_test.py | input, rendering | Application-cursor arrow sequences reach a curses application unchanged. |
| architecture_boundary_test.py | architecture | docs/ARCHITECTURE.md cites real code: every file:line reference resolves and every named constant matches its source. |
| attach_progress_budget_test.py | protocol, lifecycle | Fragmented attach traffic may progress, but one hard handshake deadline remains enforceable. |
| background_assets_test.py | UI, rendering | Built-in artwork is reproducible, valid, and safe at desktop edges. |
| badclass_test.py | UI, lifecycle | Failure to start one configured class does not terminate the user interface. |
| class_creation_transition_test.py | UI, rendering | A newly created class window is first presented with its final properties, without an intermediate wrong frame. |
| cli_help_test.py | CLI | Contextual command help is complete, navigable, truthful, and side-effect free. |
| cli_test.py | CLI | English and Spanish control commands, errors, output, and exit codes keep their public behavior. |
| client_egress_nonblocking_test.py | protocol, lifecycle | A stalled daemon cannot block the interactive client writer. |
| client_output_reactor_test.py | performance, lifecycle | A dedicated event-driven client output reactor keeps keyboard control and detach responsive when the host terminal stops draining, preserves latest-state retry and ordered animation frames, and does not change inherited stdout flags. |
| client_notifications_test.py | UI, sessions | Ordered membership changes produce only the documented local notifications. |
| clipboard_test.py | UI, input | Pane copy, ten-item history, host paste, and OSC 52 retain their visible semantics. |
| close_all_panes_test.py | UI, rendering | Closing every pane is one atomic visible transition, not a sequence of close animations. |
| concurrent_gesture_test.py | UI, protocol | Independent held gestures merge without canonical or visible rollback. |
| config_concurrency_test.py | configuration, lifecycle | Cross-process configuration, profile, and class transactions remain atomic. |
| contract_manifest_test.py | foundation | Every suite has exactly one nonempty behavior contract in all mandatory coverage areas. |
| control_test.py | protocol, CLI | Ephemeral list, send, capture, info, and window-control frames preserve replies and attachment isolation. |
| control_wm_test.py | CLI, sessions | Detached-daemon window-management commands preserve their public results. |
| cursor_test.py | UI, cleanup | Every client exit path restores the launch cursor position. |
| daemon_identity_safety_test.py | lifecycle, cleanup | Stale or malformed sidecars cannot authorize signals to a reused PID. |
| desktop_persistence_test.py | sessions, configuration | Session save/load preserves fixed logical desktop dimensions. |
| desktop_resize_protocol_test.py | protocol, sessions | Only the daemon-authoritative transaction changes canonical desktop geometry. |
| detach_test.py | sessions, lifecycle | Detach keeps PTYs live and reattach restores their current screens. |
| dialog_opaque_test.py | UI, rendering | Dialogs over artwork are fully opaque. |
| drive_test.py | UI, rendering | The basic Free Vision workspace renders the expected terminal screen. |
| empty_desktop_test.py | sessions, UI | Zero panes is a complete attachable state and concurrent recreation remains ordered. |
| exit_clean_test.py | lifecycle, cleanup | Terminal exit leaves no reporting process or terminal-state residue. |
| f5_output_layout_order_test.py | protocol, rendering | Fullscreen output and authoritative layout transitions preserve their ordering in every viewer. |
| focus_color_test.py | colour, UI | Focus changes window chrome without changing pane cell colours. |
| fresh_install_defaults_test.py | configuration, UI | A configuration-free installation starts with the advertised workspace and geometry. |
| fullscreen_test.py | UI, rendering | Maximization and terminal fullscreen remain distinct operations with reversible presentation. |
| global_command_fifo_test.py | protocol, sessions | Concurrent client commands execute through one observable global FIFO. |
| global_lock_queue_test.py | protocol, rendering | Pre-grant layout snapshots cannot roll back a completed global action. |
| host_resize_shared_test.py | sessions, UI | Host SIGWINCH changes only that viewer and never canonical desktop geometry. |
| host_summary_lease_test.py | protocol, sessions | Host compatibility metadata cannot change canonical zoom geometry or evade a lease owner. |
| language_test.py | UI, configuration | English defaults and runtime English/Spanish switching remain complete. |
| large_screen_test.py | UI, rendering | Extreme-width hosts remain local viewports over one fixed desktop. |
| late_dsr_test.py | input, protocol | A late cursor-position reply is never interpreted as a user command. |
| layout_preview_protocol_test.py | protocol, UI | Layout previews are ordered, transient, owner-scoped, and never canonical mutations. |
| layout_transition_test.py | rendering, sessions | Shared layout operations preserve exact ordered show/hide and native-control feedback without rollback; an exact software-cursor reverse toggle may share an otherwise valid frame. |
| max_panes_test.py | UI, sessions | Pane sixteen is usable and pane seventeen receives the documented refusal. |
| maximize_min_viewport_test.py | UI, sessions | Normal maximize follows the logical desktop rather than a smaller viewer. |
| mouse_focus_test.py | input, UI | Mouse menu activation and exclusive pane focus work under the documented terminal chain. |
| mouse_backend_test.py | input, lifecycle | The mouse driver is installed before FreeVision without a dependency cycle, real consoles use `KDGETMODE`, GPM is probed nonblockingly and wakes the event loop by descriptor, and PTY startup never waits for GPM. |
| mouse_test.py | input, UI | Xterm mouse events move and resize windows correctly. |
| mouseforward_test.py | input, protocol | Mouse events reach a pane application only while it has requested them. |
| mousemode_test.py | input, cleanup | Disabling any-motion tracking restores ordinary host mouse reporting. |
| multiclient_close_test.py | sessions, lifecycle | Exit and detach have one unambiguous shared-session lifetime. |
| multiclient_focus_test.py | sessions, input | Focus is shared while every attached client may write without a layout lock. |
| multiclient_input_burst_test.py | input, sessions | Concurrent attached clients can write to the shared focused pane without loss. |
| multiclient_intensive_test.py | sessions, lifecycle | Shared focus/layout/fullscreen survive intensive attachment and detachment churn; client-local membership toasts are isolated from the shared-pane convergence oracle. |
| multiclient_minimize_test.py | UI, sessions | Minimized panes keep stable shared icon slots and focus in every viewer. |
| multiclient_test.py | sessions, protocol | Versioned attach, legacy exclusion, broadcast, geometry, laggard eviction, and shutdown remain compatible. |
| multisession_test.py | sessions, CLI | Named sessions, picker, attach, and listing retain their public behavior. |
| multithread_server_test.py | lifecycle, protocol | Dynamic pane reactors preserve configuration, ordering, scaling, and teardown. |
| nesting_test.py | sessions, input | A nested SuperTerm remains usable without corrupting either terminal layer. |
| new_session_profile_test.py | sessions, configuration | New-session profile/empty selection preserves the existing daemon and selected source. |
| newwindow_test.py | UI, rendering | Opening a pane leaves existing windows unchanged. |
| nonblocking_server_test.py | protocol, lifecycle | Partial frames, stalled peers, and high descriptors cannot block the daemon. |
| palette_resize_transition_test.py | colour, rendering | Palette and local viewport changes preserve one coherent surface. |
| pane_command_interrupt_test.py | panes, lifecycle | Interrupting a pane's configured command leaves an interactive shell in that pane instead of destroying it. |
| pane_reaper_test.py | lifecycle, cleanup | The daemon owns initial-pane reaping and complete child process-group termination. |
| passthrough_modes_test.py | cleanup, rendering | Reclaiming raw fullscreen restores every host terminal mode. |
| passthrough_multiclient_test.py | protocol, rendering | Raw fullscreen is allowed only for compatible viewers with canonical geometry. |
| passthrough_test.py | protocol, rendering | Eligible fullscreen output reaches the host byte-for-byte and returns safely to rendered mode. |
| performance_harness_test.py | foundation, rendering | The interleaved baseline covers every required geometry and interaction and preserves raw latency/byte/cell/frame evidence. |
| prefix_test.py | input, configuration | Configurable prefix keys and legacy migration preserve command routing. |
| profile_default_test.py | configuration | The explicit default profile survives save and exit bookkeeping. |
| profile_shell_fallback_test.py | configuration, lifecycle | A restored console application returns to a live shell. |
| profile_switch_transition_test.py | configuration, rendering | Live profile switch closes one complete workspace before presenting the replacement. |
| profile_test.py | configuration, UI | Profiles, flattened legacy templates, and saving retain their documented model. |
| pty_spawn_safety_test.py | lifecycle, cleanup | PTY publication is bounded and binds to a verifiable child generation. |
| pyte_scrub_test.py | foundation, rendering | The closed emulator-compatibility catalogue retains split suffixes and rejects unknown parser defects. |
| reference_index_test.py | foundation | Primary references record provenance, redistribution policy, and verified catalogue checksums. |
| remote_newpane_test.py | sessions, UI | A daemon-created pane receives a corresponding local window. |
| resize_keep_test.py | rendering, UI | Shrinking uses available blank rows before scrolling content away. |
| restore_focus_test.py | UI, sessions | Minimize and restore preserve real shared focus. |
| restore_test.py | sessions, configuration | Saved sessions restore across independent runs. |
| root_output_ui_stress_test.py | performance, lifecycle | Per-pane recursive output and positive history counters remain interactive during drag, maximize/restore, pane resize, and host resize; session shutdown supersedes obsolete output backlog and every failure preserves exact crash, stack, and heap evidence. |
| screen_replies_test.py | protocol, rendering | Terminal queries answered on behalf of a pane (DA1/DA2/DSR/CPR/DECRQM/XTGETTCAP) keep their exact spelling and ordering. |
| scrollback_test.py | input, UI | History remains reachable by wheel, keys, and scrollbar. |
| screen_ascii_fastpath_test.py | performance, rendering | Printable ASCII parsing preserves wrap, rendition, UTF-8 adjacency, and screen state without per-character managed allocation. |
| session_startup_atomic_test.py | lifecycle, cleanup | Fault-injected detached startup is bounded and ownership-safe. |
| shared_geometry_test.py | sessions, UI | One fixed shared desktop is presented through independent physical viewports. |
| shared_state_stress_test.py | sessions, lifecycle | Shared focus, layout, and fullscreen survive detach/attach stress. |
| sidecar_atomic_test.py | lifecycle, protocol | Published session sidecars are complete atomic discovery snapshots. |
| sqlite_test.py | configuration | One independent template loads correctly from SQLite. |
| ssh_entry_test.py | SSH, sessions | Restricted OpenSSH entry reuses the canonical Unix-socket session. |
| ssh_release_boundary_test.py | SSH, cleanup | The installed administration binary cannot enable test-only hooks. |
| ssh_server_config_test.py | SSH, configuration | Dedicated OpenSSH administration remains isolated, strict, and idempotent. |
| ssh_service_uninstall_test.py | SSH, lifecycle | SSH service removal is exact, transactional, and packaging-safe. |
| ssh_transport_test.py | SSH, protocol | Real OpenSSH transport integration and bounded forced-command rejection work without mutating the host service, with exact process diagnostics retained on timeout. |
| stlib_crash_audit_test.py | foundation, cleanup | A dead daemon remains crash-auditable without granting authority over a reused PID. |
| stlib_reaping_test.py | foundation, cleanup | Reaped, reaped-elsewhere, vanished, stale-identity, and leaked outcomes stay distinct and safe. |
| stlib_transition_capture_test.py | foundation, rendering | The transition oracle never merges a truncated synchronized-output frame. |
| strict_build_test.py | foundation, lifecycle | Release, debug, and test-runtime builds reject every source warning, note, and hint. |
| suite_manifest_test.py | foundation | Makefile template, generated Makefile, and suite files have one identical inventory. |
| sysconfig_test.py | configuration | System terminal definitions, scrollback, and local fallback autosave preserve precedence. |
| template_test.py | configuration, UI | Named templates, windows, SQLite model, and switching remain compatible. |
| terminal_encoding_test.py | rendering, protocol | Per-client UTF-8 probing and 7-bit compatibility rendering preserve text. |
| title_hold_focus_test.py | input, rendering | A held title gesture never transfers focus to an underlying window. |
| title_test.py | UI, configuration | Per-window titles remain editable and persistent. |
| wclass_test.py | configuration, UI | User/system window classes and legacy aliases retain merge behavior. |
| window_test.py | input, UI | Move, zoom, minimize, restore, and window controls retain visible behavior. |
| wire_constants_test.py | foundation, protocol | The frozen Python wire table and Pascal server declarations cannot drift. |
| wireframe_preview_test.py | rendering, sessions | Wireframe previews remain identical and transient in all viewers. |
| wizard_test.py | UI, configuration | Wizard routing and deferred pane materialization retain their outcomes. |
| zoom_exclusive_switch_test.py | UI, sessions | Maximized-pane handoff is globally exclusive and preserves restore geometry. |
