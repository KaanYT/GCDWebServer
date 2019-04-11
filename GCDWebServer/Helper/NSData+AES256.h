//
//  NSData+AES256.h
//  GCDWebServer
//
//  Created by Kaan Eksen on 11.04.2019.
//

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCryptor.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSData (AES256)

- (NSData *)AES256EncryptWithKey:(NSString *)key;
- (NSData *)AES256DecryptWithKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
