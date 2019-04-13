/*
 Copyright (c) 2012-2019, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if !__has_feature(objc_arc)
#error GCDWebServer requires ARC
#endif

#import <sys/stat.h>

#import "GCDWebServerPrivate.h"
#import "NSData+AES256.h"

#define kFileReadBufferSize (32 * 1024)

@implementation GCDWebServerFileResponse {
  NSString* _path;
  NSString* _dataInfo;
  BOOL _activateDataInfo;
  NSUInteger _offset;
  NSUInteger _size;
  int _file;
}

@dynamic contentType, lastModifiedDate, eTag;

+ (instancetype)responseWithFile:(NSString*)path {
  return [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path];
}

+ (instancetype)responseWithFile:(NSString*)path Info:(NSString*)info ActivateDataInfo:(BOOL)activateInfo {
  return [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:NO mimeTypeOverrides:NULL info:info activateDataInfo:activateInfo];
}

+ (instancetype)responseWithFile:(NSString*)path isAttachment:(BOOL)attachment {
  return [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path isAttachment:attachment];
}

+ (instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range {
  return [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path byteRange:range];
}

+ (instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range Info:(NSString*)info ActivateDataInfo:(BOOL)activateInfo {
  return  [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path byteRange:range isAttachment:NO mimeTypeOverrides:NULL info:info activateDataInfo:activateInfo];
}

+ (instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range isAttachment:(BOOL)attachment {
  return [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path byteRange:range isAttachment:attachment mimeTypeOverrides:nil info:nil activateDataInfo:NO];
}

+ (nullable instancetype)responseWithFile:(NSString*)path isAttachment:(BOOL)attachment Info:(NSString*)info ActivateDataInfo:(BOOL)activateInfo{
  return [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:attachment mimeTypeOverrides:nil info:info activateDataInfo:activateInfo];
}

+ (nullable instancetype)responseWithFile:(NSString*)path byteRange:(NSRange)range isAttachment:(BOOL)attachment Info:(NSString*)info ActivateDataInfo:(BOOL)activateInfo{
  return [(GCDWebServerFileResponse*)[[self class] alloc] initWithFile:path byteRange:range isAttachment:attachment mimeTypeOverrides:nil info:info activateDataInfo:activateInfo];
}

- (instancetype)initWithFile:(NSString*)path {
  return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:NO mimeTypeOverrides:nil info:nil activateDataInfo:NO];
}

- (instancetype)initWithFile:(NSString*)path isAttachment:(BOOL)attachment {
  return [self initWithFile:path byteRange:NSMakeRange(NSUIntegerMax, 0) isAttachment:attachment mimeTypeOverrides:nil info:nil activateDataInfo:NO];
}

- (instancetype)initWithFile:(NSString*)path byteRange:(NSRange)range {
  return [self initWithFile:path byteRange:range isAttachment:NO mimeTypeOverrides:nil info:@"" activateDataInfo:NO];
}

static inline NSDate* _NSDateFromTimeSpec(const struct timespec* t) {
  return [NSDate dateWithTimeIntervalSince1970:((NSTimeInterval)t->tv_sec + (NSTimeInterval)t->tv_nsec / 1000000000.0)];
}

- (instancetype)initWithFile:(NSString*)path byteRange:(NSRange)range isAttachment:(BOOL)attachment mimeTypeOverrides:(NSDictionary<NSString*, NSString*>*)overrides info:(NSString*)dataInfo activateDataInfo:(BOOL)activateInfo {
  struct stat info;
  if (lstat([path fileSystemRepresentation], &info) || !(info.st_mode & S_IFREG)) {
    GWS_DNOT_REACHED();
    return nil;
  }
#ifndef __LP64__
  if (info.st_size >= (off_t)4294967295) {  // In 32 bit mode, we can't handle files greater than 4 GiBs (don't use "NSUIntegerMax" here to avoid potential unsigned to signed conversion issues)
    GWS_DNOT_REACHED();
    return nil;
  }
#endif
  NSUInteger fileSize = (NSUInteger)info.st_size;

  BOOL hasByteRange = GCDWebServerIsValidByteRange(range);
  if (hasByteRange) {
    if (range.location != NSUIntegerMax) {
      range.location = MIN(range.location, fileSize);
      range.length = MIN(range.length, fileSize - range.location);
    } else {
      range.length = MIN(range.length, fileSize);
      range.location = fileSize - range.length;
    }
    if (range.length == 0) {
      return nil;  // TODO: Return 416 status code and "Content-Range: bytes */{file length}" header
    }
  } else {
    range.location = 0;
    range.length = fileSize;
  }

  if ((self = [super init])) {
    _path = [path copy];
    _offset = range.location;
    _size = range.length;
    _dataInfo = [_dataInfo copy];
    _activateDataInfo = NO;
    if (hasByteRange) {
      [self setStatusCode:kGCDWebServerHTTPStatusCode_PartialContent];
      [self setValue:[NSString stringWithFormat:@"bytes %lu-%lu/%lu", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), (unsigned long)fileSize] forAdditionalHeader:@"Content-Range"];
      GWS_LOG_DEBUG(@"Using content bytes range [%lu-%lu] for file \"%@\"", (unsigned long)_offset, (unsigned long)(_offset + _size - 1), path);
    }

    if (attachment) {
      NSString* fileName = [path lastPathComponent];
      NSData* data = [[fileName stringByReplacingOccurrencesOfString:@"\"" withString:@""] dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:YES];
      NSString* lossyFileName = data ? [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] : nil;
      if (lossyFileName) {
        NSString* value = [NSString stringWithFormat:@"attachment; filename=\"%@\"; filename*=UTF-8''%@", lossyFileName, GCDWebServerEscapeURLString(fileName)];
        [self setValue:value forAdditionalHeader:@"Content-Disposition"];
      } else {
        GWS_DNOT_REACHED();
      }
    }

    self.contentType = GCDWebServerGetMimeTypeForExtension([_path pathExtension], overrides);
    _activateDataInfo = activateInfo;
    _dataInfo = dataInfo;
    if (activateInfo) {
      self.contentLength = [self readDataForContentLenght];
      _size = self.contentLength;
    }else{
      self.contentLength = _size;
    }
    self.lastModifiedDate = _NSDateFromTimeSpec(&info.st_mtimespec);
    self.eTag = [NSString stringWithFormat:@"%llu/%li/%li", info.st_ino, info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec];
  }
  return self;
}

- (BOOL)open:(NSError**)error {
  _file = open([_path fileSystemRepresentation], O_NOFOLLOW | O_RDONLY);
  if (_file <= 0) {
    if (error) {
      *error = GCDWebServerMakePosixError(errno);
    }
    return NO;
  }
  if (lseek(_file, _offset, SEEK_SET) != (off_t)_offset) {
    if (error) {
      *error = GCDWebServerMakePosixError(errno);
    }
    close(_file);
    return NO;
  }
  return YES;
}

- (void)readInfo:(NSString*)info ActivateDataInfo:(BOOL)activateInfo{
  _activateDataInfo = activateInfo;
  _dataInfo = info;
}

- (NSUInteger)readDataForContentLenght{
  NSData* data = [NSData dataWithContentsOfFile:_path];
  data = [data AES256DecryptWithKey:_dataInfo];
  return data.length;
}

- (NSData*)readData:(NSError**)error {
  if (!_activateDataInfo) {
    size_t length = MIN((NSUInteger)kFileReadBufferSize, _size);
    NSMutableData* data = [[NSMutableData alloc] initWithLength:length];
    ssize_t result = read(_file, data.mutableBytes, length);
    if (result < 0) {
      if (error) {
        *error = GCDWebServerMakePosixError(errno);
      }
      return nil;
    }
    if (result > 0) {
      [data setLength:result];
      _size -= result;
    }
    return data;
  }else{
    size_t length = MIN((NSUInteger)kFileReadBufferSize, _size);
    NSData* data = [[NSData dataWithContentsOfFile:_path] AES256DecryptWithKey:_dataInfo];
    NSUInteger start = data.length-_size;
    NSData* partial =  [data subdataWithRange:NSMakeRange(start,length)];
    _size -= length;
    self.contentLength = partial.length;
    return partial;
  }
}

- (void)close {
  close(_file);
}

- (NSString*)description {
  NSMutableString* description = [NSMutableString stringWithString:[super description]];
  [description appendFormat:@"\n\n{%@}", _path];
  return description;
}

@end
