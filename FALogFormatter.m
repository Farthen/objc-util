//
//  FALogFormatter.m
//
//  Created by Finn Wilke on 15.03.13.
//  Copyright (c) 2013 Finn Wilke. All rights reserved.
//

#import "FALogFormatter.h"

@implementation FALogFormatter {
    NSDateFormatter *_dateFormatter;
}

- (id)init
{
    self = [super init];
    
    if (self) {
        _dateFormatter = [[NSDateFormatter alloc] init];
        _dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    }
    
    return self;
}

- (NSString *)formatLogMessage:(DDLogMessage *)logMessage
{
    NSString *logLevel;
    
    switch (logMessage.flag) {
        case DDLogFlagError: logLevel = @"ERROR"; break;
            
        case DDLogFlagWarning: logLevel = @"WARN"; break;
            
        case DDLogFlagInfo: logLevel = @"INFO"; break;
            
        case DDLogFlagDebug: logLevel = @"SMALL"; break;
            
        case DDLogFlagVerbose: logLevel = @"VERBOSE"; break;
            
        default: logLevel = @"UNKNOWN"; break;
    }
    
    NSDate *date = logMessage.timestamp;
    NSString *dateString = [_dateFormatter stringFromDate:date];
#ifdef DEBUG
    //Also display the file the logging occurred in to ease later debugging
    NSString *file = [[logMessage.file lastPathComponent] stringByDeletingPathExtension];
    NSString *threadId = [NSString stringWithFormat:@"T:0x%@", logMessage.threadID];
    
    //Format the message
    return [NSString stringWithFormat:@"%@ %@ [%@]: \"%@\" || [%@@%@%lu]", dateString, threadId, logLevel, logMessage.message, file, logMessage.function, (unsigned long)logMessage.line];
#else
    
    return [NSString stringWithFormat:@"%@ [%@]: %@", dateString, logLevel, logMessage.message];
#endif
}

@end
