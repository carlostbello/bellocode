#ifndef BELLOCODE_TEST_PROCESS_SETUP_H
#define BELLOCODE_TEST_PROCESS_SETUP_H

/// 1 when SIGPIPE is ignored in this process (the bundle's load-time setup ran).
int bellocode_test_process_setup_ran(void);

#endif
