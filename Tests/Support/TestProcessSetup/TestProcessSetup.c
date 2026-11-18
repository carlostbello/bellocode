// Process-wide setup for every test bundle, run when the bundle is loaded (before any test).
//
// SIGPIPE: a write to a pipe or socket whose reader is gone must fail with EPIPE, not kill the whole test process
// (an EngineTests and a ContainerKitTests run each died once with signal 13). The app ignores SIGPIPE at launch
// (BelloCodeMain); the test runner does not, so each bundle does it here. Individual pipes and sockets also set
// F_SETNOSIGPIPE / SO_NOSIGPIPE, so this is the backstop, not the only guard.
#include <signal.h>
#include "TestProcessSetup.h"

__attribute__((constructor)) static void bellocode_test_process_setup(void) {
    signal(SIGPIPE, SIG_IGN);
}

int bellocode_test_process_setup_ran(void) {
    struct sigaction current;
    if (sigaction(SIGPIPE, NULL, &current) != 0) return 0;
    return current.sa_handler == SIG_IGN;
}
