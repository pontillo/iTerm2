// -*- mode:objc -*-
// $Id: $
/*
 **  LineBuffer.h
 **
 **  Copyright (c) 2002, 2003
 **
 **  Author: George Nachman
 **
 **  Project: iTerm
 **
 **  Description: Implements a buffer of lines. It can hold a large number
 **   of lines and can quickly format them to a fixed width.
 **
 **  This program is free software; you can redistribute it and/or modify
 **  it under the terms of the GNU General Public License as published by
 **  the Free Software Foundation; either version 2 of the License, or
 **  (at your option) any later version.
 **
 **  This program is distributed in the hope that it will be useful,
 **  but WITHOUT ANY WARRANTY; without even the implied warranty of
 **  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 **  GNU General Public License for more details.
 **
 **  You should have received a copy of the GNU General Public License
 **  along with this program; if not, write to the Free Software
 **  Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
 */

#import "LineBuffer.h"

#import "BackgroundThread.h"
#import "LineBlock.h"
#import "RegexKitLite/RegexKitLite.h"
#import "TrackedObject.h"

@implementation LineBuffer

// Append a block
- (LineBlock*) _addBlockOfSize: (int) size
{
    LineBlock* block = [[LineBlock alloc] initWithRawBufferSize: size];
    [blocks addObject: block];
    [block release];
    return block;
}

// The designated initializer. We prefer not to explose the notion of block sizes to
// clients, so this is internal.
- (LineBuffer*)initWithBlockSize:(int)bs
{
    self = [super init];
    if (self) {
        block_size = bs;
        blocks = [[NSMutableArray alloc] initWithCapacity: 1];
        [self _addBlockOfSize: block_size];
        max_lines = -1;
        num_wrapped_lines_width = -1;
        num_dropped_blocks = 0;
    }
    return self;
}

- (void)dealloc
{
    // This causes the blocks to be released in a background thread.
    // When a LineBuffer is really gigantic, it can take
    // quite a bit of time to release all the blocks.
    [blocks performSelector:@selector(removeAllObjects)
                   onThread:[BackgroundThread backgroundThread]
                 withObject:nil
              waitUntilDone:NO];
    [blocks release];
    [super dealloc];
}

// This is called a lot so it's a C function to avoid obj_msgSend
static int RawNumLines(LineBuffer* buffer, int width) {
    if (buffer->num_wrapped_lines_width == width) {
        return buffer->num_wrapped_lines_cache;
    }
    int count = 0;
    int i;
    for (i = 0; i < [buffer->blocks count]; ++i) {
        LineBlock* block = [buffer->blocks objectAtIndex: i];
        count += [block getNumLinesWithWrapWidth: width];
    }
    buffer->num_wrapped_lines_width = width;
    buffer->num_wrapped_lines_cache = count;
    return count;
}

// drop lines if needed until max_lines is reached.
- (void) _dropLinesForWidth: (int) width
{
    if (max_lines == -1) {
        // Do nothing: the buffer is infinite.
        return;
    }

    int total_lines = RawNumLines(self, width);
    while (total_lines > max_lines) {
        int extra_lines = total_lines - max_lines;

        NSAssert([blocks count] > 0, @"No blocks");
        LineBlock* block = [blocks objectAtIndex: 0];
        int block_lines = [block getNumLinesWithWrapWidth: width];
        NSAssert(block_lines > 0, @"Empty leading block");
        int toDrop = block_lines;
        if (toDrop > extra_lines) {
            toDrop = extra_lines;
        }
        int charsDropped;
        int dropped = [block dropLines:toDrop withWidth:width chars:&charsDropped];
        droppedChars += charsDropped;
        if ([block isEmpty]) {
            [blocks removeObjectAtIndex:0];
            ++num_dropped_blocks;
        }
        total_lines -= dropped;
    }
    num_wrapped_lines_cache = total_lines;
}

- (void) setMaxLines: (int) maxLines
{
    max_lines = maxLines;
    num_wrapped_lines_width = -1;
}


- (int) dropExcessLinesWithWidth: (int) width
{
    int nl = RawNumLines(self, width);
    if (nl > max_lines) {
        [self _dropLinesForWidth: width];
    }
    return nl - RawNumLines(self, width);
}

- (NSString *)debugString {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < [blocks count]; i++) {
        LineBlock *block = [blocks objectAtIndex:i];
        [block appendToDebugString:s];
    }
    return [s length] ? [s substringToIndex:s.length - 1] : @"";  // strip trailing newline
}

- (void) dump
{
    int i;
    int rawOffset = 0;
    for (i = 0; i < [blocks count]; ++i) {
        NSLog(@"Block %d:\n", i);
        [[blocks objectAtIndex: i] dump:rawOffset];
        rawOffset += [[blocks objectAtIndex:i] rawSpaceUsed];
    }
}

- (NSString *)compactLineDumpWithWidth:(int)width {
    NSMutableString *s = [NSMutableString string];
    int n = [self numLinesWithWidth:width];
    for (int i = 0; i < n; i++) {
        ScreenCharArray *line = [self wrappedLineAtIndex:i width:width];
        [s appendFormat:@"%@", ScreenCharArrayToStringDebug(line.line, line.length)];
        for (int j = line.length; j < width; j++) {
            [s appendString:@"."];
        }
        if (i < n - 1) {
            [s appendString:@"\n"];
        }
    }
    return s;
}

- (void)dumpWrappedToWidth:(int)width
{
    NSLog(@"%@", [self compactLineDumpWithWidth:width]);
}

- (LineBuffer*)init
{
    // I picked 8k because it's a multiple of the page size and should hold about 100-200 lines
    // on average. Very small blocks make finding a wrapped line expensive because caching the
    // number of wrapped lines is spread out over more blocks. Very large blocks are expensive
    // because of the linear search through a block for the start of a wrapped line. This is
    // in the middle. Ideally, the number of blocks would equal the number of wrapped lines per
    // block, and this should be in that neighborhood for typical uses.
    const int BLOCK_SIZE = 1024 * 8;
    return [self initWithBlockSize:BLOCK_SIZE];
}

- (void)appendLine:(screen_char_t*)buffer
            length:(int)length
           partial:(BOOL)partial
             width:(int)width
         timestamp:(NSTimeInterval)timestamp
            object:(id<TrackedObject>)object
{
#ifdef LOG_MUTATIONS
    {
        char a[1000];
        int i;
        for (i = 0; i < length; i++) {
            a[i] = (buffer[i].code && !buffer[i].complex) ? buffer[i].code : '.';
        }
        a[i] = '\0';
        NSLog(@"Append: %s\n", a);
    }
#endif
    if ([blocks count] == 0) {
        [self _addBlockOfSize: block_size];
    }

    LineBlock* block = [blocks objectAtIndex: ([blocks count] - 1)];

    if (object) {
        object.isInLineBuffer = YES;
        object.lineBufferPosition = [self lastPosition];
    }
    int beforeLines = [block getNumLinesWithWrapWidth:width];
    if (![block appendLine:buffer length:length partial:partial width:width timestamp:timestamp object:object]) {
        // It's going to be complicated. Invalidate the number of wrapped lines
        // cache.
        num_wrapped_lines_width = -1;
        int prefix_len = 0;
        NSTimeInterval prefixTimestamp = 0;
        id<TrackedObject> prefixObject = nil;
        screen_char_t* prefix = NULL;
        if ([block hasPartial]) {
            // There is a line that's too long for the current block to hold.
            // Remove its prefix fromt he current block and later add the
            // concatenation of prefix + buffer to a larger block.
            screen_char_t* temp;
            BOOL ok = [block popLastLineInto:&temp
                                  withLength:&prefix_len
                                   upToWidth:[block rawBufferSize]+1
                                   timestamp:&prefixTimestamp
                                      object:&prefixObject];
            assert(ok);
            prefix = (screen_char_t*) malloc(MAX(1, prefix_len) * sizeof(screen_char_t));
            memcpy(prefix, temp, prefix_len * sizeof(screen_char_t));
            NSAssert(ok, @"hasPartial but pop failed.");
        }
        if ([block isEmpty]) {
            // The buffer is empty but it's not large enough to hold a whole line. It must be grown.
            if (partial) {
                // The line is partial so we know there's more coming. Allocate enough space to hold the current line
                // plus the usual block size (this is the case when the line is freaking huge).
                // We could double the size to ensure better asymptotic runtime but you'd run out of memory
                // faster with huge lines.
                [block changeBufferSize: length + prefix_len + block_size];
            } else {
                // Allocate exactly enough space to hold this one line.
                [block changeBufferSize: length + prefix_len];
            }
        } else {
            // The existing buffer can't hold this line, but it has preceding line(s). Shrink it and
            // allocate a new buffer that is large enough to hold this line.
            [block shrinkToFit];
            if (length + prefix_len > block_size) {
                block = [self _addBlockOfSize: length + prefix_len];
            } else {
                block = [self _addBlockOfSize: block_size];
            }
        }

        // Append the prefix if there is one (the prefix was a partial line that we're
        // moving out of the last block into the new block)
        if (prefix) {
            BOOL ok = [block appendLine:prefix length:prefix_len partial:YES width:width timestamp:prefixTimestamp object:prefixObject];
            NSAssert(ok, @"append can't fail here");
            free(prefix);
        }
        // Finally, append this line to the new block. We know it'll fit because we made
        // enough room for it.
        BOOL ok = [block appendLine:buffer length:length partial:partial width:width timestamp:timestamp object:object];
        NSAssert(ok, @"append can't fail here");
    } else if (num_wrapped_lines_width == width) {
        // Straightforward addition of a line to an existing block. Update the
        // wrapped lines cache.
        int afterLines = [block getNumLinesWithWrapWidth:width];
        num_wrapped_lines_cache += (afterLines - beforeLines);
    } else {
        // Width change. Invalidate the wrapped lines cache.
        num_wrapped_lines_width = -1;
    }
}

- (NSTimeInterval)timestampForLineNumber:(int)lineNum width:(int)width
{
    int line = lineNum;
    int i;
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        NSAssert(block, @"Null block");
        
        // getNumLinesWithWrapWidth caches its result for the last-used width so
        // this is usually faster than calling getWrappedLineWithWrapWidth since
        // most calls to the latter will just decrement line and return NULL.
        int block_lines = [block getNumLinesWithWrapWidth:width];
        if (block_lines < line) {
            line -= block_lines;
            continue;
        }
        
        return [block timestampForLineNumber:line width:width];
    }
    return 0;
}

- (id<TrackedObject>)objectForLineNumber:(int)lineNum width:(int)width
{
    int line = lineNum;
    int i;
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        NSAssert(block, @"Null block");
        
        // getNumLinesWithWrapWidth caches its result for the last-used width so
        // this is usually faster than calling getWrappedLineWithWrapWidth since
        // most calls to the latter will just decrement line and return NULL.
        int block_lines = [block getNumLinesWithWrapWidth:width];
        if (block_lines < line) {
            line -= block_lines;
            continue;
        }
        
        return [block objectForLineNumber:line width:width];
    }
    return 0;
}

- (void)setObject:(id<TrackedObject>)object forLine:(int)lineNum width:(int)width {
    int line = lineNum;
    int i;
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        NSAssert(block, @"Null block");
        
        // getNumLinesWithWrapWidth caches its result for the last-used width so
        // this is usually faster than calling getWrappedLineWithWrapWidth since
        // most calls to the latter will just decrement line and return NULL.
        int block_lines = [block getNumLinesWithWrapWidth:width];
        if (block_lines < line) {
            line -= block_lines;
            continue;
        }

        LineBufferPosition *position = [self positionForCoordinate:VT100GridCoordMake(0, lineNum)
                                                             width:width
                                                            offset:0];
        if (position) {
            [block setObject:object forLine:line width:width];
            object.isInLineBuffer = YES;
            object.lineBufferPosition = position;
        } else {
            NSLog(@"Couldn't convert line number %d with width %d to position, not adding object.",
                  lineNum, width);
        }
        return;
    }
}

// Copy a line into the buffer. If the line is shorter than 'width' then only
// the first 'width' characters will be modified.
// 0 <= lineNum < numLinesWithWidth:width
- (int) copyLineToBuffer: (screen_char_t*) buffer width: (int) width lineNum: (int) lineNum
{
    int line = lineNum;
    int i;
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex: i];
        NSAssert(block, @"Null block");

        // getNumLinesWithWrapWidth caches its result for the last-used width so
        // this is usually faster than calling getWrappedLineWithWrapWidth since
        // most calls to the latter will just decrement line and return NULL.
        int block_lines = [block getNumLinesWithWrapWidth:width];
        if (block_lines < line) {
            line -= block_lines;
            continue;
        }

        int length;
        int eol;
        screen_char_t* p = [block getWrappedLineWithWrapWidth: width
                                                      lineNum: &line
                                                   lineLength: &length
                                            includesEndOfLine: &eol];
        if (p) {
            NSAssert(length <= width, @"Length too long");
            memcpy((char*) buffer, (char*) p, length * sizeof(screen_char_t));
            return eol;
        }
    }
    NSLog(@"Couldn't find line %d", lineNum);
    NSAssert(NO, @"Tried to get non-existant line");
    return NO;
}

- (ScreenCharArray *)wrappedLineAtIndex:(int)lineNum width:(int)width
{
    int line = lineNum;
    int i;
    ScreenCharArray *result = [[[ScreenCharArray alloc] init] autorelease];
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];

        // getNumLinesWithWrapWidth caches its result for the last-used width so
        // this is usually faster than calling getWrappedLineWithWrapWidth since
        // most calls to the latter will just decrement line and return NULL.
        int block_lines = [block getNumLinesWithWrapWidth:width];
        if (block_lines < line) {
            line -= block_lines;
            continue;
        }

        int length, eol;
        result.line = [block getWrappedLineWithWrapWidth:width
                                                 lineNum:&line
                                              lineLength:&length
                                       includesEndOfLine:&eol];
        if (result.line) {
            result.length = length;
            result.eol = eol;
            NSAssert(result.length <= width, @"Length too long");
            return result;
        }
    }
    NSLog(@"Couldn't find line %d", lineNum);
    NSAssert(NO, @"Tried to get non-existant line");
    return nil;
}

- (int) numLinesWithWidth: (int) width
{
    return RawNumLines(self, width);
}

- (BOOL)popAndCopyLastLineInto:(screen_char_t*)ptr
                         width:(int)width
             includesEndOfLine:(int*)includesEndOfLine
                     timestamp:(NSTimeInterval *)timestampPtr
                        object:(id<TrackedObject> *)objectPtr
{
    if ([self numLinesWithWidth: width] == 0) {
        return NO;
    }
    num_wrapped_lines_width = -1;

    LineBlock* block = [blocks lastObject];

    // If the line is partial the client will want to add a continuation marker so
    // tell him there's no EOL in that case.
    *includesEndOfLine = [block hasPartial] ? EOL_SOFT : EOL_HARD;

    // Pop the last up-to-width chars off the last line.
    int length;
    screen_char_t* temp;
    BOOL ok = [block popLastLineInto:&temp
                          withLength:&length
                           upToWidth:width
                           timestamp:timestampPtr
                              object:objectPtr];
    NSAssert(ok, @"Unexpected empty block");
    NSAssert(length <= width, @"Length too large");
    NSAssert(length >= 0, @"Negative length");

    // Copy into the provided buffer.
    memcpy(ptr, temp, sizeof(screen_char_t) * length);

    // Clean up the block if the whole thing is empty, otherwise another call
    // to this function would not work correctly.
    if ([block isEmpty]) {
        [blocks removeLastObject];
    }

#ifdef LOG_MUTATIONS
    {
        char a[1000];
        int i;
        for (i = 0; i < width; i++) {
            a[i] = (ptr[i].code && !ptr[i].complexChar) ? ptr[i].code : '.';
        }
        a[i] = '\0';
        NSLog(@"Pop: %s\n", a);
    }
#endif
    if (objectPtr) {
        (*objectPtr).isInLineBuffer = NO;
    }
    return YES;
}

- (void) setCursor: (int) x
{
    LineBlock* block = [blocks lastObject];
    if ([block hasPartial]) {
        int last_line_length = [block getRawLineLength: [block numEntries]-1];
        cursor_x = x + last_line_length;
        cursor_rawline = -1;
    } else {
        cursor_x = x;
        cursor_rawline = 0;
    }

    int i;
    for (i = 0; i < [blocks count]; ++i) {
        cursor_rawline += [[blocks objectAtIndex: i] numRawLines];
    }
}

- (BOOL) getCursorInLastLineWithWidth: (int) width atX: (int*) x
{
    int total_raw_lines = 0;
    int i;
    for (i = 0; i < [blocks count]; ++i) {
        total_raw_lines += [[blocks objectAtIndex:i] numRawLines];
    }
    if (cursor_rawline == total_raw_lines-1) {
        // The cursor is on the last line in the buffer.
        LineBlock* block = [blocks lastObject];
        int last_line_length = [block getRawLineLength: ([block numEntries]-1)];
        screen_char_t* lastRawLine = [block rawLine: ([block numEntries]-1)];
        int num_overflow_lines = NumberOfFullLines(lastRawLine,
                                                   last_line_length,
                                                   width);
        int min_x = OffsetOfWrappedLine(lastRawLine,
                                        num_overflow_lines,
                                        last_line_length,
                                        width);
        //int num_overflow_lines = (last_line_length-1) / width;
        //int min_x = num_overflow_lines * width;
        int max_x = min_x + width;  // inclusive because the cursor wraps to the next line on the last line in the buffer
        if (cursor_x >= min_x && cursor_x <= max_x) {
            *x = cursor_x - min_x;
            return YES;
        }
    }
    return NO;
}

- (BOOL)_findPosition:(LineBufferPosition *)start inBlock:(int*)block_num inOffset:(int*)offset
{
    int i;
    int position = start.absolutePosition - droppedChars;
    for (i = 0; position >= 0 && i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        int used = [block rawSpaceUsed];
        if (position >= used) {
            position -= used;
        } else {
            *block_num = i;
            *offset = position;
            return YES;
        }
    }
    return NO;
}

- (int) _blockPosition: (int) block_num
{
    int i;
    int position = 0;
    for (i = 0; i < block_num; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        position += [block rawSpaceUsed];
    }
    return position;

}

- (void)prepareToSearchFor:(NSString*)substring
                startingAt:(LineBufferPosition *)start
                   options:(int)options
               withContext:(FindContext*)context
{
    context.substring = substring;
    context.options = options;
    if (options & FindOptBackwards) {
        context.dir = -1;
    } else {
        context.dir = 1;
    }
    int offset = context.offset;
    int absBlockNum = context.absBlockNum;
    if ([self _findPosition:start inBlock:&absBlockNum inOffset:&offset]) {
        context.offset = offset;
        context.absBlockNum = absBlockNum + num_dropped_blocks;
        context.status = Searching;
    } else {
        context.status = NotFound;
    }
    context.results = [NSMutableArray array];
}

- (void)findSubstring:(FindContext*)context stopAt:(int)stopAt
{
    if (context.dir > 0) {
        // Search forwards
        if (context.absBlockNum < num_dropped_blocks) {
            // The next block to search was dropped. Skip ahead to the first block.
            // NSLog(@"Next to search was dropped. Skip to start");
            context.absBlockNum = num_dropped_blocks;
        }
        if (context.absBlockNum - num_dropped_blocks >= [blocks count]) {
            // Got to bottom
            // NSLog(@"Got to bottom");
            context.status = NotFound;
            return;
        }
    } else {
        // Search backwards
        if (context.absBlockNum < num_dropped_blocks) {
            // Got to top
            // NSLog(@"Got to top");
            context.status = NotFound;
            return;
        }
    }

    NSAssert(context.absBlockNum - num_dropped_blocks >= 0, @"bounds check");
    NSAssert(context.absBlockNum - num_dropped_blocks < [blocks count], @"bounds check");
    LineBlock* block = [blocks objectAtIndex:context.absBlockNum - num_dropped_blocks];

    if (context.absBlockNum - num_dropped_blocks == 0 &&
        context.offset != -1 &&
        context.offset < [block startOffset]) {
        if (context.dir > 0) {
            // Part of the first block has been dropped. Skip ahead to its
            // current beginning.
            context.offset = [block startOffset];
        } else {
            // This block has scrolled off.
            // NSLog(@"offset=%d, block's startOffset=%d. give up", context.offset, [block startOffset]);
            context.status = NotFound;
            return;
        }
    }

    // NSLog(@"search block %d starting at offset %d", context.absBlockNum - num_dropped_blocks, context.offset);

    [block findSubstring:context.substring
                 options:context.options
                atOffset:context.offset
                 results:context.results
         multipleResults:((context.options & FindMultipleResults) != 0)];
    NSMutableArray* filtered = [NSMutableArray arrayWithCapacity:[context.results count]];
    BOOL haveOutOfRangeResults = NO;
    int blockPosition = [self _blockPosition:context.absBlockNum - num_dropped_blocks];
    for (ResultRange* range in context.results) {
        range->position += blockPosition;
        if (context.dir * (range->position - stopAt) > 0 ||
            context.dir * (range->position + context.matchLength - stopAt) > 0) {
            // result was outside the range to be searched
            haveOutOfRangeResults = YES;
        } else {
            // Found a good result.
            context.status = Matched;
            [filtered addObject:range];
        }
    }
    context.results = filtered;
    if ([filtered count] == 0 && haveOutOfRangeResults) {
        context.status = NotFound;
    }

    // Prepare to continue searching next block.
    if (context.dir < 0) {
        context.offset = -1;
    } else {
        context.offset = 0;
    }
    context.absBlockNum = context.absBlockNum + context.dir;
}

// Returns an array of XRange values
- (NSArray*)convertPositions:(NSArray*)resultRanges withWidth:(int)width
{
    // Create sorted array of all positions to convert.
    NSMutableArray* unsortedPositions = [NSMutableArray arrayWithCapacity:[resultRanges count] * 2];
    for (ResultRange* rr in resultRanges) {
        [unsortedPositions addObject:[NSNumber numberWithInt:rr->position]];
        [unsortedPositions addObject:[NSNumber numberWithInt:rr->position + rr->length - 1]];
    }

    // Walk blocks and positions in parallel, converting each position in order. Store in
    // intermediate dict, mapping position->NSPoint(x,y)
    NSArray *positionsArray = [unsortedPositions sortedArrayUsingSelector:@selector(compare:)];
    int i = 0;
    int yoffset = 0;
    int numBlocks = [blocks count];
    int passed = 0;
    LineBlock *block = [blocks objectAtIndex:0];
    int used = [block rawSpaceUsed];
    NSMutableDictionary* intermediate = [NSMutableDictionary dictionaryWithCapacity:[resultRanges count] * 2];
    int prev = -1;
    for (NSNumber* positionNum in positionsArray) {
        int position = [positionNum intValue];
        if (position == prev) {
            continue;
        }
        prev = position;

        // Advance block until it includes this position
        while (position >= passed + used && i < numBlocks) {
            passed += used;
            yoffset += [block getNumLinesWithWrapWidth:width];
            i++;
            if (i < numBlocks) {
                block = [blocks objectAtIndex:i];
                used = [block rawSpaceUsed];
            }
        }
        if (i < numBlocks) {
            int x, y;
            assert(position >= passed);
            assert(position < passed + used);
            assert(used == [block rawSpaceUsed]);
            BOOL isOk = [block convertPosition:position - passed
                                     withWidth:width
                                           toX:&x
                                           toY:&y];
            assert(x < 2000);
            if (isOk) {
                y += yoffset;
                [intermediate setObject:[NSValue valueWithPoint:NSMakePoint(x, y)]
                                 forKey:positionNum];
            } else {
                assert(false);
            }
        }
    }

    // Walk the positions array and populate results by looking up points in intermediate dict.
    NSMutableArray* result = [NSMutableArray arrayWithCapacity:[resultRanges count]];
    for (ResultRange* rr in resultRanges) {
        NSValue *start = [intermediate objectForKey:[NSNumber numberWithInt:rr->position]];
        NSValue *end = [intermediate objectForKey:[NSNumber numberWithInt:rr->position + rr->length - 1]];
        if (start && end) {
            XYRange *xyrange = [[[XYRange alloc] init] autorelease];
            NSPoint startPoint = [start pointValue];
            NSPoint endPoint = [end pointValue];
            xyrange->xStart = startPoint.x;
            xyrange->yStart = startPoint.y;
            xyrange->xEnd = endPoint.x;
            xyrange->yEnd = endPoint.y;
            [result addObject:xyrange];
        } else {
            assert(false);
            [result addObject:[NSNull null]];
        }
    }

    return result;
}

// Returns YES if the position is valid.
- (BOOL)convertPosition:(int)position
              withWidth:(int)width
                    toX:(int*)x
                    toY:(int*)y
{
    BOOL ok;
    LineBufferPosition *lbp = [LineBufferPosition position];
    lbp.absolutePosition = position + droppedChars;
    lbp.yOffset = 0;
    lbp.extendsToEndOfLine = NO;
    VT100GridCoord coord = [self coordinateForPosition:lbp width:width ok:&ok];
    *x = coord.x;
    *y = coord.y;
    return ok;
}

- (LineBufferPosition *)positionForCoordinate:(VT100GridCoord)coord
                                        width:(int)width
                                       offset:(int)offset
{
    int x = coord.x;
    int y = coord.y;
    long long absolutePosition = droppedChars;

    int line = y;
    int i;
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex: i];
        NSAssert(block, @"Null block");

        // getNumLinesWithWrapWidth caches its result for the last-used width so
        // this is usually faster than calling getWrappedLineWithWrapWidth since
        // most calls to the latter will just decrement line and return NULL.
        int block_lines = [block getNumLinesWithWrapWidth:width];
        if (block_lines <= line) {
            line -= block_lines;
            absolutePosition += [block rawSpaceUsed];
            continue;
        }

        int pos;
        int yOffset = 0;
        BOOL extends = NO;
        pos = [block getPositionOfLine:&line
                                   atX:x
                             withWidth:width
                               yOffset:&yOffset
                               extends:&extends];
        if (pos >= 0) {
            absolutePosition += pos + offset;
            LineBufferPosition *result = [LineBufferPosition position];
            result.absolutePosition = absolutePosition;
            result.yOffset = yOffset;
            result.extendsToEndOfLine = extends;

            // Make sure position is valid (might not be because of offset).
            BOOL ok;
            [self coordinateForPosition:result width:width ok:&ok];
            if (ok) {
                return result;
            } else {
                return nil;
            }
        }
    }
    return nil;
}

- (VT100GridCoord)coordinateForPosition:(LineBufferPosition *)position
                                  width:(int)width
                                     ok:(BOOL *)ok
{
    if (position.absolutePosition == [self lastPos] + droppedChars) {
        VT100GridCoord result;
        result.y = [self numLinesWithWidth:width] - 1;
        ScreenCharArray *lastLine = [self wrappedLineAtIndex:result.y width:width];
        result.x = lastLine.length;
        if (position.yOffset > 0) {
            result.x = 0;
            result.y += position.yOffset;
        } else {
            result.x = lastLine.length;
        }
        if (position.extendsToEndOfLine) {
            result.x = width - 1;
        }
        if (ok) {
            *ok = YES;
        }
        return result;
    }
    int i;
    int yoffset = 0;
    int p = position.absolutePosition - droppedChars;
    for (i = 0; p >= 0 && i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        int used = [block rawSpaceUsed];
        if (p >= used) {
            p -= used;
            yoffset += [block getNumLinesWithWrapWidth:width];
        } else {
            int y;
            int x;
            BOOL positionIsValid = [block convertPosition:p
                                                withWidth:width
                                                      toX:&x
                                                      toY:&y];
            if (ok) {
                *ok = positionIsValid;
            }
            if (position.yOffset > 0) {
                x = 0;
                y += position.yOffset;
            }
            if (position.extendsToEndOfLine) {
                x = width - 1;
            }
            return VT100GridCoordMake(x, y + yoffset);
        }
    }
    if (ok) {
        *ok = NO;
    }
    return VT100GridCoordMake(0, 0);
}

- (int) firstPos
{
    int i;
    int position = 0;
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        if (![block isEmpty]) {
            position += [block startOffset];
            break;
        } else {
            position += [block rawSpaceUsed];
        }
    }
    return position;
}

- (int) lastPos
{
    int i;
    int position = 0;
    for (i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        if (![block isEmpty]) {
            position += [block rawSpaceUsed];
        } else {
            position += [block rawSpaceUsed];
        }
    }
    return position;
}

- (LineBufferPosition *)firstPosition {
    LineBufferPosition *position = [LineBufferPosition position];
    position.absolutePosition = droppedChars;
    return position;
}

- (LineBufferPosition *)lastPosition {
    LineBufferPosition *position = [LineBufferPosition position];

    position.absolutePosition = droppedChars;
    for (int i = 0; i < [blocks count]; ++i) {
        LineBlock* block = [blocks objectAtIndex:i];
        position.absolutePosition = position.absolutePosition + [block rawSpaceUsed];
    }

    return position;
}

- (long long)absPositionOfFindContext:(FindContext *)findContext
{
    long long offset = droppedChars + findContext.offset;
    int numBlocks = findContext.absBlockNum - num_dropped_blocks;
    for (LineBlock *block in blocks) {
        if (!numBlocks) {
            break;
        }
        --numBlocks;
        offset += [block rawSpaceUsed];
    }
    return offset;
}

- (int)positionForAbsPosition:(long long)absPosition
{
    absPosition -= droppedChars;
    if (absPosition < 0) {
        return [[blocks objectAtIndex:0] startOffset];
    }
    if (absPosition > INT_MAX) {
        absPosition = INT_MAX;
    }
    return (int)absPosition;
}

- (long long)absPositionForPosition:(int)pos
{
    long long absPos = pos;
    return absPos + droppedChars;
}

- (int)absBlockNumberOfAbsPos:(long long)absPos
{
    int absBlock = num_dropped_blocks;
    long long cumPos = droppedChars;
    for (LineBlock *block in blocks) {
        cumPos += [block rawSpaceUsed];
        if (cumPos >= absPos) {
            return absBlock;
        }
        ++absBlock;
    }
    return absBlock;
}

- (long long)absPositionOfAbsBlock:(int)absBlockNum
{
    long long cumPos = droppedChars;
    for (int i = 0; i < blocks.count && i + num_dropped_blocks < absBlockNum; i++) {
        cumPos += [[blocks objectAtIndex:i] rawSpaceUsed];
    }
    return cumPos;
}

- (void)storeLocationOfAbsPos:(long long)absPos
                    inContext:(FindContext *)context
{
    context.absBlockNum = [self absBlockNumberOfAbsPos:absPos];
    long long absOffset = [self absPositionOfAbsBlock:context.absBlockNum];
    context.offset = MAX(0, absPos - absOffset);
}

- (LineBuffer *)newAppendOnlyCopy {
    LineBuffer *theCopy = [[LineBuffer alloc] init];
    theCopy->blocks = [[NSMutableArray alloc] initWithArray:blocks];
    LineBlock *lastBlock = [blocks lastObject];
    if (lastBlock) {
        [theCopy->blocks removeLastObject];
        [theCopy->blocks addObject:[[lastBlock copy] autorelease]];
    }
    theCopy->block_size = block_size;
    theCopy->cursor_x = cursor_x;
    theCopy->cursor_rawline = cursor_rawline;
    theCopy->max_lines = max_lines;
    theCopy->num_dropped_blocks = num_dropped_blocks;
    theCopy->num_wrapped_lines_cache = num_wrapped_lines_cache;
    theCopy->num_wrapped_lines_width = num_wrapped_lines_width;
    theCopy->droppedChars = droppedChars;

    return theCopy;
}

@end
