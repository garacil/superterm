These units are the Free Vision sources from Free Pascal 3.2.2
(source commit `0d122c49534b480be9284c21bd60b53d99904346`).

The system Free Vision units cap views at 255 columns and store the detected
screen dimensions in byte-sized fields. Superterm needs wider terminal panes,
so `views.pas` and `drivers.pas` use a 1024-column draw buffer and word-sized
screen dimensions. The remaining units are rebuilt with them because their
interfaces depend on the Free Vision view and driver units.

`compile.sh` adds this directory before the installed Free Vision unit path;
the system package is not modified.
