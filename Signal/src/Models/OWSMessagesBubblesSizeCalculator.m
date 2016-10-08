//  Copyright (c) 2016 Open Whisper Systems. All rights reserved.

#import "OWSMessagesBubblesSizeCalculator.h"
#import "OWSCall.h"
#import "OWSDisplayedMessageCollectionViewCell.h"
#import "TSMessageAdapter.h"
#import "UIFont+OWS.h"
#import "tgmath.h" // generic math allows fmax to handle CGFLoat correctly on 32 & 64bit.
#import <JSQMessagesViewController/JSQMessagesCollectionViewFlowLayout.h>

NS_ASSUME_NONNULL_BEGIN

// BEGIN HACK iOS10EmojiBug see: https://github.com/WhisperSystems/Signal-iOS/issues/1368
// superclass protected methods we need in order to compute bubble size.
@interface OWSMessagesBubblesSizeCalculator (OWSiOS10EmojiBug)

@property (strong, nonatomic, readonly) NSCache *cache;
@property (assign, nonatomic, readonly) NSUInteger minimumBubbleWidth;
@property (assign, nonatomic, readonly) BOOL usesFixedWidthBubbles;
@property (assign, nonatomic, readonly) NSInteger additionalInset;
@property (assign, nonatomic) CGFloat layoutWidthForFixedWidthBubbles;

- (CGSize)jsq_avatarSizeForMessageData:(id<JSQMessageData>)messageData
                            withLayout:(JSQMessagesCollectionViewFlowLayout *)layout;
- (CGFloat)textBubbleWidthForLayout:(JSQMessagesCollectionViewFlowLayout *)layout;
@end
// END HACK iOS10EmojiBug see: https://github.com/WhisperSystems/Signal-iOS/issues/1368

@implementation OWSMessagesBubblesSizeCalculator

/**
 *  Computes and returns the size of the `messageBubbleImageView` property
 *  of a `JSQMessagesCollectionViewCell` for the specified messageData at indexPath.
 *
 *  @param messageData A message data object.
 *  @param indexPath   The index path at which messageData is located.
 *  @param layout      The layout object asking for this information.
 *
 *  @return A sizes that specifies the required dimensions to display the entire message contents.
 *  Note, this is *not* the entire cell, but only its message bubble.
 */
- (CGSize)messageBubbleSizeForMessageData:(id<JSQMessageData>)messageData
                              atIndexPath:(NSIndexPath *)indexPath
                               withLayout:(JSQMessagesCollectionViewFlowLayout *)layout
{
    if ([messageData isKindOfClass:[TSMessageAdapter class]]) {
        TSMessageAdapter *message = (TSMessageAdapter *)messageData;
        if (message.messageType == TSInfoMessageAdapter || message.messageType == TSErrorMessageAdapter) {
            return [self messageBubbleSizeForInfoMessageData:messageData atIndexPath:indexPath withLayout:layout];
        }
    }

    if ([messageData isKindOfClass:[OWSCall class]]) {
        return [self messageBubbleSizeForCallData:messageData atIndexPath:indexPath withLayout:layout];
    }

    CGSize size;
    // BEGIN HACK iOS10EmojiBug see: https://github.com/WhisperSystems/Signal-iOS/issues/1368
    BOOL isIOS10OrGreater =
        [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){.majorVersion = 10 }];
    if (isIOS10OrGreater) {
        size = [self withiOS10EmojiFixSuperMessageBubbleSizeForMessageData:messageData
                                                               atIndexPath:indexPath
                                                                withLayout:layout];
    } else {
        size = [super messageBubbleSizeForMessageData:messageData atIndexPath:indexPath withLayout:layout];
    }
    // END HACK iOS10EmojiBug see: https://github.com/WhisperSystems/Signal-iOS/issues/1368



    return size;
}

/**
 * HACK iOS10EmojiBug see: https://github.com/WhisperSystems/Signal-iOS/issues/1368
 * iOS10 bug in rendering emoji requires to fudge some things in the middle of the super method.
 * Copy/pasted the superclass method and inlined (and marked) our hacks inline.
 */
- (CGSize)withiOS10EmojiFixSuperMessageBubbleSizeForMessageData:(id<JSQMessageData>)messageData
                                                    atIndexPath:(NSIndexPath *)indexPath
                                                     withLayout:(JSQMessagesCollectionViewFlowLayout *)layout
{
    NSValue *cachedSize = [self.cache objectForKey:@([messageData messageHash])];
    if (cachedSize != nil) {
        return [cachedSize CGSizeValue];
    }

    CGSize finalSize = CGSizeZero;

    if ([messageData isMediaMessage]) {
        finalSize = [[messageData media] mediaViewDisplaySize];
    } else {
        CGSize avatarSize = [self jsq_avatarSizeForMessageData:messageData withLayout:layout];

        //  from the cell xibs, there is a 2 point space between avatar and bubble
        CGFloat spacingBetweenAvatarAndBubble = 2.0f;
        CGFloat horizontalContainerInsets = layout.messageBubbleTextViewTextContainerInsets.left
            + layout.messageBubbleTextViewTextContainerInsets.right;
        CGFloat horizontalFrameInsets
            = layout.messageBubbleTextViewFrameInsets.left + layout.messageBubbleTextViewFrameInsets.right;

        CGFloat horizontalInsetsTotal
            = horizontalContainerInsets + horizontalFrameInsets + spacingBetweenAvatarAndBubble;
        CGFloat maximumTextWidth = [self textBubbleWidthForLayout:layout] - avatarSize.width
            - layout.messageBubbleLeftRightMargin - horizontalInsetsTotal;

        ///////////////////
        // BEGIN HACK iOS10EmojiBug see: https://github.com/WhisperSystems/Signal-iOS/issues/1368

        // //stringRect doesn't give the correct size with the new emoji font.
        // CGRect stringRect = [[messageData text] boundingRectWithSize:CGSizeMake(maximumTextWidth, CGFLOAT_MAX)
        //                                                              options:(NSStringDrawingUsesLineFragmentOrigin |
        //                                                              NSStringDrawingUsesFontLeading)
        //                                                           attributes:@{ NSFontAttributeName :
        //                                                           layout.messageBubbleFont }
        //                                                              context:nil];

        CGRect stringRect;
        if (!messageData.text) {
            stringRect = CGRectZero;
        } else {
            NSDictionary *attributes = @{ NSFontAttributeName : layout.messageBubbleFont };
            NSMutableAttributedString *string =
                [[NSMutableAttributedString alloc] initWithString:[messageData text] attributes:attributes];
            [string fixAttributesInRange:NSMakeRange(0, string.length)];
            [string
                enumerateAttribute:NSFontAttributeName
                           inRange:NSMakeRange(0, string.length)
                           options:0
                        usingBlock:^(id _Nullable value, NSRange range, BOOL *_Nonnull stop) {
                            UIFont *font = (UIFont *)value;
                            if ([font.fontName isEqualToString:@".AppleColorEmojiUI"]) {
                                DDLogVerbose(@"Replacing new broken emoji font with old emoji font at location: %lu, "
                                             @"for length: %lu",
                                    (unsigned long)range.location,
                                    (unsigned long)range.length);
                                [string addAttribute:NSFontAttributeName
                                               value:[UIFont fontWithName:@"AppleColorEmoji" size:font.pointSize]
                                               range:range];
                            }
                        }];
            stringRect =
                [string boundingRectWithSize:CGSizeMake(maximumTextWidth, CGFLOAT_MAX)
                                     options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                     context:nil];
        }
        // END HACK iOS10EmojiBug see: https://github.com/WhisperSystems/Signal-iOS/issues/1368
        /////////////////////////

        CGSize stringSize = CGRectIntegral(stringRect).size;

        CGFloat verticalContainerInsets = layout.messageBubbleTextViewTextContainerInsets.top
            + layout.messageBubbleTextViewTextContainerInsets.bottom;
        CGFloat verticalFrameInsets
            = layout.messageBubbleTextViewFrameInsets.top + layout.messageBubbleTextViewFrameInsets.bottom;

        //  add extra 2 points of space (`self.additionalInset`), because `boundingRectWithSize:` is slightly off
        //  not sure why. magix. (shrug) if you know, submit a PR
        CGFloat verticalInsets = verticalContainerInsets + verticalFrameInsets + self.additionalInset;

        //  same as above, an extra 2 points of magix
        CGFloat finalWidth
            = MAX(stringSize.width + horizontalInsetsTotal, self.minimumBubbleWidth) + self.additionalInset;

        finalSize = CGSizeMake(finalWidth, stringSize.height + verticalInsets);
    }

    [self.cache setObject:[NSValue valueWithCGSize:finalSize] forKey:@([messageData messageHash])];

    return finalSize;
}


- (CGSize)messageBubbleSizeForInfoMessageData:(id<JSQMessageData>)messageData
                                  atIndexPath:(NSIndexPath *)indexPath
                                   withLayout:(JSQMessagesCollectionViewFlowLayout *)layout
{
    NSValue *cachedSize = [self.cache objectForKey:@([messageData messageHash])];
    if (cachedSize != nil) {
        return [cachedSize CGSizeValue];
    }

    CGSize finalSize = CGSizeZero;

    if ([messageData isMediaMessage]) {
        finalSize = [[messageData media] mediaViewDisplaySize];
    } else {
        ///////////////////
        // BEGIN InfoMessage sizing HACK
        // Braindead, and painstakingly produced.
        // If you want to change, check for clipping / excess space on 1, 2, and 3 line messages with short and long
        // words very near the edge.

//      CGSize avatarSize = [self jsq_avatarSizeForMessageData:messageData withLayout:layout];
//      //  from the cell xibs, there is a 2 point space between avatar and bubble
//      CGFloat spacingBetweenAvatarAndBubble = 2.0f;
//      CGFloat horizontalContainerInsets = layout.messageBubbleTextViewTextContainerInsets.left + layout.messageBubbleTextViewTextContainerInsets.right;
//      CGFloat horizontalFrameInsets = layout.messageBubbleTextViewFrameInsets.left + layout.messageBubbleTextViewFrameInsets.right;
//      CGFloat horizontalInsetsTotal = horizontalContainerInsets + horizontalFrameInsets + spacingBetweenAvatarAndBubble;
//      CGFloat maximumTextWidth = [self textBubbleWidthForLayout:layout] - avatarSize.width - layout.messageBubbleLeftRightMargin - horizontalInsetsTotal;

        // The full layout width, less the textView margins from xib.
//        CGFloat horizontalInsetsTotal = 12.0; cropped 3rd line
        CGFloat horizontalInsetsTotal = 50.0;
        CGFloat maximumTextWidth = [self textBubbleWidthForLayout:layout] - horizontalInsetsTotal;

        CGRect stringRect = [[messageData text]
            boundingRectWithSize:CGSizeMake(maximumTextWidth, CGFLOAT_MAX)
                         options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                      attributes:@{
                                   NSFontAttributeName : [UIFont ows_dynamicTypeBodyFont]
                      } // Hack to use a slightly larger than actual font, because I'm seeing messages with higher line count get clipped.
                         context:nil];
        // END InfoMessage sizing HACK
        ////////////////////

        CGSize stringSize = CGRectIntegral(stringRect).size;

        CGFloat verticalContainerInsets = layout.messageBubbleTextViewTextContainerInsets.top
            + layout.messageBubbleTextViewTextContainerInsets.bottom;

        CGFloat verticalFrameInsets
            = layout.messageBubbleTextViewFrameInsets.top + layout.messageBubbleTextViewFrameInsets.bottom;
        ///////////////////
        // BEGIN InfoMessage sizing HACK

        CGFloat topIconPortrusion = 28;

        verticalFrameInsets += topIconPortrusion;

        // END InfoMessage sizing HACK
        ///////////////////

        //  add extra 2 points of space (`self.additionalInset`), because `boundingRectWithSize:` is slightly off
        //  not sure why. magix. (shrug) if you know, submit a PR
        CGFloat verticalInsets = verticalContainerInsets + verticalFrameInsets + self.additionalInset;

        //  same as above, an extra 2 points of magix
        CGFloat finalWidth
            = MAX(stringSize.width + horizontalInsetsTotal, self.minimumBubbleWidth) + self.additionalInset;

        finalSize = CGSizeMake(finalWidth, stringSize.height + verticalInsets);
    }

    [self.cache setObject:[NSValue valueWithCGSize:finalSize] forKey:@([messageData messageHash])];

    return finalSize;
}

- (CGSize)messageBubbleSizeForCallData:(id<JSQMessageData>)messageData
                           atIndexPath:(NSIndexPath *)indexPath
                            withLayout:(JSQMessagesCollectionViewFlowLayout *)layout
{
    NSValue *cachedSize = [self.cache objectForKey:@([messageData messageHash])];
    if (cachedSize != nil) {
        return [cachedSize CGSizeValue];
    }

    CGFloat horizontalInsetsTotal = 0.0;
    CGFloat maximumTextWidth = [self textBubbleWidthForLayout:layout] - horizontalInsetsTotal;

    CGRect stringRect = [[messageData text]
        boundingRectWithSize:CGSizeMake(maximumTextWidth, CGFLOAT_MAX)
                     options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                  attributes:@{
                      NSFontAttributeName : [UIFont ows_dynamicTypeBodyFont]
                  } // Hack to use a slightly larger than actual font, because I'm seeing messages with higher line
                    // count get clipped.
                     context:nil];

    CGSize stringSize = CGRectIntegral(stringRect).size;

    CGFloat verticalInsets = 0;
    CGFloat finalWidth = maximumTextWidth + horizontalInsetsTotal;

    CGSize finalSize = CGSizeMake(finalWidth, stringSize.height + verticalInsets);

    [self.cache setObject:[NSValue valueWithCGSize:finalSize] forKey:@([messageData messageHash])];

    return finalSize;
}

@end

NS_ASSUME_NONNULL_END
