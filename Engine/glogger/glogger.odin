package glog

import "core:log"

// Global logger instance
g_logger: log.Logger

initialize :: proc() {
    g_logger = log.Logger{}
}