//
//  GrowCut_m.h
//  OsiriX
//
//  Created by Antoine Rosset on 22.06.2025.
//  Copyright © 2025 OsiriX Team. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN


@interface GrowCut2D : NSObject

@property NSInteger width;
@property NSInteger height;
@property (retain) NSMutableArray<NSMutableArray<NSValue *> *> *cells;
@property (retain) NSArray<NSArray<NSNumber *> *> *image;

- (instancetype)initWithImage:(NSArray<NSArray<NSNumber *> *> *)image seeds:(NSDictionary<NSValue *, NSNumber *> *)seeds;
- (void)runWithIterations:(NSInteger)iterations;
- (NSArray<NSArray<NSNumber *> *> *)labelMap;

@end


@interface GrowCut3D : NSObject

@property NSInteger width;
@property NSInteger height;
@property NSInteger depth;
@property (retain) NSMutableArray<NSMutableArray<NSMutableArray<NSValue *> *> *> *cells;
@property (retain) NSArray<NSArray<NSArray<NSNumber *> *> *> *volume;

- (instancetype)initWithVolume:(NSArray<NSArray<NSArray<NSNumber *> *> *> *)volume seeds:(NSDictionary<NSValue *, NSNumber *> *)seeds;
- (void)runWithIterations:(NSInteger)iterations;
- (NSArray<NSArray<NSArray<NSNumber *> *> *> *)labelVolume;

@end


NS_ASSUME_NONNULL_END
