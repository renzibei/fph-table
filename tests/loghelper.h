#pragma once

#include <cstdio>
#include <utility>

// #define LOG_HELPER_LEVEL_LOG_TRACE
#define LOG_HELPER_LEVEL_LOG_DEBUG



enum  LogType{Error, Warn, Info, Debug, Trace};

class LogHelper {

public:

    // Counts of what happened, so a caller can end with a verdict instead of
    // leaving the reader to spot red text. tests/CMakeLists.txt also matches
    // the Error escape sequence below; the two are independent on purpose.
    static unsigned long &error_count() {
        static unsigned long n = 0;
        return n;
    }

    // Incremented by each correctness check the suite completes. main() refuses
    // to report success when too few of them ran: a suite that returns without
    // testing anything otherwise passes in no time at all.
    static unsigned long &check_count() {
        static unsigned long n = 0;
        return n;
    }

    /**
     * A printf style log function, can used glog as underlying output tool
     * @tparam Args
     * @param type
     * @param format
     * @param args
     */
    template<typename... Args>
    static void log(LogType type, const char * format, Args&&... args) {
#ifdef LOG_TRACE
        if(type <= Trace)
#elif defined LOG_HELPER_LEVEL_LOG_DEBUG
        if(type <= Debug)
#elif defined LOG_INFO
        if(type <= Info)
#elif defined LOG_WARN
        if(type <= Warn)
#endif
        {
            if (type == Error) {
                ++error_count();
                fprintf(stderr, "\033[40;31m");
            }
            else if (type == Warn) {
                fprintf(stderr, "\033[40;33m");
            }
            fprintf(stderr, format, std::forward<Args>(args)...);
            if (type == Error || type == Warn) {
                fprintf(stderr, "\033[0m");
            }
            fprintf(stderr, "\n");

        }
    }
};
