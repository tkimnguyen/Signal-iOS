//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "MediaDetailViewController.h"
#import "AttachmentSharing.h"
#import "ConversationViewController.h"
#import "ConversationViewItem.h"
#import "OWSMessageCell.h"
#import "Signal-Swift.h"
#import "TSAttachmentStream.h"
#import "TSInteraction.h"
#import "UIColor+OWS.h"
#import "UIUtil.h"
#import "UIView+OWS.h"
#import <AVKit/AVKit.h>
#import <MediaPlayer/MPMoviePlayerViewController.h>
#import <MediaPlayer/MediaPlayer.h>
#import <SignalMessaging/SignalMessaging-Swift.h>
#import <SignalServiceKit/NSData+Image.h>
#import <YYImage/YYImage.h>

NS_ASSUME_NONNULL_BEGIN

// In order to use UIMenuController, the view from which it is
// presented must have certain custom behaviors.
@interface AttachmentMenuView : UIView

@end

#pragma mark -

@implementation AttachmentMenuView

- (BOOL)canBecomeFirstResponder
{
    return YES;
}

// We only use custom actions in UIMenuController.
- (BOOL)canPerformAction:(SEL)action withSender:(nullable id)sender
{
    return NO;
}

@end

#pragma mark -

@interface MediaDetailViewController () <UIScrollViewDelegate,
    UIGestureRecognizerDelegate,
    PlayerProgressBarDelegate,
    OWSVideoPlayerDelegate>

@property (nonatomic) UIScrollView *scrollView;
@property (nonatomic) UIView *mediaView;
@property (nonatomic) UIView *presentationView;
@property (nonatomic) UIView *replacingView;
@property (nonatomic) UIButton *shareButton;

@property (nonatomic) CGRect originRect;
@property (nonatomic) NSData *fileData;

@property (nonatomic, nullable) TSAttachmentStream *attachmentStream;
@property (nonatomic, nullable) ConversationViewItem *viewItem;

@property (nonatomic, nullable) OWSVideoPlayer *videoPlayer;
@property (nonatomic, nullable) UIButton *playVideoButton;
@property (nonatomic, nullable) PlayerProgressBar *videoProgressBar;
@property (nonatomic, nullable) UIBarButtonItem *videoPlayBarButton;
@property (nonatomic, nullable) UIBarButtonItem *videoPauseBarButton;

@property (nonatomic, nullable) NSArray<NSLayoutConstraint *> *presentationViewConstraints;
@property (nonatomic, nullable) NSLayoutConstraint *mediaViewBottomConstraint;
@property (nonatomic, nullable) NSLayoutConstraint *mediaViewLeadingConstraint;
@property (nonatomic, nullable) NSLayoutConstraint *mediaViewTopConstraint;
@property (nonatomic, nullable) NSLayoutConstraint *mediaViewTrailingConstraint;

@end

@implementation MediaDetailViewController

- (instancetype)initWithAttachmentStream:(TSAttachmentStream *)attachmentStream
                                viewItem:(ConversationViewItem *_Nullable)viewItem
{
    self = [super initWithNibName:nil bundle:nil];
    if (!self) {
        return self;
    }

    self.attachmentStream = attachmentStream;
    self.viewItem = viewItem;

    return self;
}

- (NSURL *_Nullable)attachmentUrl
{
    return self.attachmentStream.mediaURL;
}

- (NSData *)fileData
{
    if (!_fileData) {
        NSURL *_Nullable url = self.attachmentUrl;
        if (url) {
            _fileData = [NSData dataWithContentsOfURL:url];
        }
    }
    return _fileData;
}

- (UIImage *)image
{
    return self.attachmentStream.image;
}

- (BOOL)isAnimated
{
    return self.attachmentStream.isAnimated;
}

- (BOOL)isVideo
{
    return self.attachmentStream.isVideo;
}

- (void)loadView
{
    self.view = [AttachmentMenuView new];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self createContents];
    [self initializeGestureRecognizers];

    // Even though bars are opaque, we want content to be layed out behind them.
    // The bars might obscure part of the content, but they can easily be hidden by tapping
    // The alternative would be that content would shift when the navbars hide.
    self.extendedLayoutIncludesOpaqueBars = YES;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self resetMediaFrame];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];

    if ([UIMenuController sharedMenuController].isMenuVisible) {
        [[UIMenuController sharedMenuController] setMenuVisible:NO animated:NO];
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];

    [self updateMinZoomScale];
    [self centerMediaViewConstraints];
}

- (void)updateMinZoomScale
{
    CGSize viewSize = self.scrollView.bounds.size;
    UIImage *image = self.image;
    OWSAssert(image);

    if (image.size.width == 0 || image.size.height == 0) {
        OWSFail(@"%@ Invalid image dimensions. %@", self.logTag, NSStringFromCGSize(image.size));
        return;
    }

    CGFloat scaleWidth = viewSize.width / image.size.width;
    CGFloat scaleHeight = viewSize.height / image.size.height;
    CGFloat minScale = MIN(scaleWidth, scaleHeight);

    if (minScale != self.scrollView.minimumZoomScale) {
        self.scrollView.minimumZoomScale = minScale;
        self.scrollView.maximumZoomScale = minScale * 8;
        self.scrollView.zoomScale = minScale;
    }
}

- (void)zoomOutAnimated:(BOOL)isAnimated
{
    if (self.scrollView.zoomScale != self.scrollView.minimumZoomScale) {
        [self.scrollView setZoomScale:self.scrollView.minimumZoomScale animated:isAnimated];
    }
}

#pragma mark - Initializers

- (void)createContents
{
    UIScrollView *scrollView = [UIScrollView new];
    [self.view addSubview:scrollView];
    self.scrollView = scrollView;
    scrollView.delegate = self;

    scrollView.showsVerticalScrollIndicator = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.decelerationRate = UIScrollViewDecelerationRateFast;

    if (@available(iOS 11.0, *)) {
        scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    } else {
        self.automaticallyAdjustsScrollViewInsets = NO;
    }

    [scrollView autoPinToSuperviewEdges];

    if (self.isAnimated) {
        if ([self.fileData ows_isValidImage]) {
            YYImage *animatedGif = [YYImage imageWithData:self.fileData];
            YYAnimatedImageView *animatedView = [YYAnimatedImageView new];
            animatedView.image = animatedGif;
            self.mediaView = animatedView;
        } else {
            self.mediaView = [UIImageView new];
        }
    } else if (self.isVideo) {
        self.mediaView = [self buildVideoPlayerView];
    } else {
        // Present the static image using standard UIImageView
        UIImageView *imageView = [[UIImageView alloc] initWithImage:self.image];

        self.mediaView = imageView;
    }

    OWSAssert(self.mediaView);

    [scrollView addSubview:self.mediaView];
    self.mediaViewLeadingConstraint = [self.mediaView autoPinEdgeToSuperviewEdge:ALEdgeLeading];
    self.mediaViewTopConstraint = [self.mediaView autoPinEdgeToSuperviewEdge:ALEdgeTop];
    self.mediaViewTrailingConstraint = [self.mediaView autoPinEdgeToSuperviewEdge:ALEdgeTrailing];
    self.mediaViewBottomConstraint = [self.mediaView autoPinEdgeToSuperviewEdge:ALEdgeBottom];

    self.mediaView.contentMode = UIViewContentModeScaleAspectFit;
    self.mediaView.userInteractionEnabled = YES;
    self.mediaView.clipsToBounds = YES;
    self.mediaView.layer.allowsEdgeAntialiasing = YES;
    self.mediaView.translatesAutoresizingMaskIntoConstraints = NO;

    // Use trilinear filters for better scaling quality at
    // some performance cost.
    self.mediaView.layer.minificationFilter = kCAFilterTrilinear;
    self.mediaView.layer.magnificationFilter = kCAFilterTrilinear;

    if (self.isVideo) {
        PlayerProgressBar *videoProgressBar = [PlayerProgressBar new];
        videoProgressBar.delegate = self;
        videoProgressBar.player = self.videoPlayer.avPlayer;

        // We hide the progress bar until either:
        // 1. Video completes playing
        // 2. User taps the screen
        videoProgressBar.hidden = YES;

        self.videoProgressBar = videoProgressBar;
        [self.view addSubview:videoProgressBar];
        [videoProgressBar autoPinWidthToSuperview];
        [videoProgressBar autoPinToTopLayoutGuideOfViewController:self withInset:0];
        CGFloat kVideoProgressBarHeight = 44;
        [videoProgressBar autoSetDimension:ALDimensionHeight toSize:kVideoProgressBarHeight];

        UIButton *playVideoButton = [UIButton new];
        self.playVideoButton = playVideoButton;

        [playVideoButton addTarget:self action:@selector(playVideo) forControlEvents:UIControlEventTouchUpInside];

        UIImage *playImage = [UIImage imageNamed:@"play_button"];
        [playVideoButton setBackgroundImage:playImage forState:UIControlStateNormal];
        playVideoButton.contentMode = UIViewContentModeScaleAspectFill;

        [self.view addSubview:playVideoButton];

        CGFloat playVideoButtonWidth = ScaleFromIPhone5(70);
        [playVideoButton autoSetDimensionsToSize:CGSizeMake(playVideoButtonWidth, playVideoButtonWidth)];
        [playVideoButton autoCenterInSuperview];
    }
}

- (UIView *)buildVideoPlayerView
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:[self.attachmentUrl path]]) {
        OWSFail(@"%@ Missing video file: %@", self.logTag, self.attachmentStream.mediaURL);
    }

    OWSVideoPlayer *player = [[OWSVideoPlayer alloc] initWithUrl:self.attachmentUrl];
    [player seekToTime:kCMTimeZero];
    player.delegate = self;
    self.videoPlayer = player;

    VideoPlayerView *playerView = [VideoPlayerView new];
    playerView.player = player.avPlayer;

    [NSLayoutConstraint autoSetPriority:UILayoutPriorityDefaultLow
                         forConstraints:^{
                             [playerView autoSetDimensionsToSize:self.image.size];
                         }];

    return playerView;
}

- (void)setShouldHideToolbars:(BOOL)shouldHideToolbars
{
    self.videoProgressBar.hidden = shouldHideToolbars;
}

- (void)initializeGestureRecognizers
{
    UITapGestureRecognizer *doubleTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didDoubleTapImage:)];
    doubleTap.numberOfTapsRequired = 2;
    [self.view addGestureRecognizer:doubleTap];

    UILongPressGestureRecognizer *longPress =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressGesture:)];
    longPress.delegate = self;
    [self.view addGestureRecognizer:longPress];
}

#pragma mark - Gesture Recognizers

- (void)didDoubleTapImage:(UITapGestureRecognizer *)gesture
{
    DDLogVerbose(@"%@ did double tap image.", self.logTag);
    if (self.scrollView.zoomScale == self.scrollView.minimumZoomScale) {
        CGFloat kDoubleTapZoomScale = 2;

        CGFloat zoomWidth = self.scrollView.width / kDoubleTapZoomScale;
        CGFloat zoomHeight = self.scrollView.height / kDoubleTapZoomScale;

        // center zoom rect around tapLocation
        CGPoint tapLocation = [gesture locationInView:self.scrollView];
        CGFloat zoomX = MAX(0, tapLocation.x - zoomWidth / 2);
        CGFloat zoomY = MAX(0, tapLocation.y - zoomHeight / 2);

        CGRect zoomRect = CGRectMake(zoomX, zoomY, zoomWidth, zoomHeight);

        CGRect translatedRect = [self.mediaView convertRect:zoomRect fromView:self.scrollView];

        [self.scrollView zoomToRect:translatedRect animated:YES];
    } else {
        // If already zoomed in at all, zoom out all the way.
        [self zoomOutAnimated:YES];
    }
}

- (void)longPressGesture:(UIGestureRecognizer *)sender
{
    // We "eagerly" respond when the long press begins, not when it ends.
    if (sender.state == UIGestureRecognizerStateBegan) {
        if (!self.viewItem) {
            return;
        }

        [self.view becomeFirstResponder];

        if ([UIMenuController sharedMenuController].isMenuVisible) {
            [[UIMenuController sharedMenuController] setMenuVisible:NO animated:NO];
        }

        NSArray *menuItems = self.viewItem.mediaMenuControllerItems;
        [UIMenuController sharedMenuController].menuItems = menuItems;
        CGPoint location = [sender locationInView:self.view];
        CGRect targetRect = CGRectMake(location.x, location.y, 1, 1);
        [[UIMenuController sharedMenuController] setTargetRect:targetRect inView:self.view];
        [[UIMenuController sharedMenuController] setMenuVisible:YES animated:YES];
    }
}

- (void)didPressShare:(id)sender
{
    DDLogInfo(@"%@: didPressShare", self.logTag);
    if (!self.viewItem) {
        OWSFail(@"share should only be available when a viewItem is present");
        return;
    }

    [self.viewItem shareMediaAction];
}

- (void)didPressDelete:(id)sender
{
    DDLogInfo(@"%@: didPressDelete", self.logTag);
    if (!self.viewItem) {
        OWSFail(@"delete should only be available when a viewItem is present");
        return;
    }

    UIAlertController *actionSheet =
        [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    [actionSheet
        addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"TXT_DELETE_TITLE", nil)
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action) {
                                             OWSAssert([self.presentingViewController
                                                 isKindOfClass:[UINavigationController class]]);
                                             UINavigationController *navController
                                                 = (UINavigationController *)self.presentingViewController;

                                             if ([navController.topViewController
                                                     isKindOfClass:[ConversationViewController class]]) {
                                                 [self.delegate dismissSelfAnimated:YES
                                                                         completion:^{
                                                                             [self.viewItem deleteAction];
                                                                         }];
                                             } else if ([navController.topViewController
                                                            isKindOfClass:[MessageDetailViewController class]]) {
                                                 [self.delegate dismissSelfAnimated:YES
                                                                         completion:^{
                                                                             [self.viewItem deleteAction];
                                                                         }];
                                                 [navController popViewControllerAnimated:YES];
                                             } else {
                                                 OWSFail(@"Unexpected presentation context.");
                                                 [self.delegate dismissSelfAnimated:YES
                                                                         completion:^{
                                                                             [self.viewItem deleteAction];
                                                                         }];
                                             }
                                         }]];

    [actionSheet addAction:[OWSAlerts cancelAction]];

    [self presentViewController:actionSheet animated:YES completion:nil];
}

- (BOOL)canPerformAction:(SEL)action withSender:(nullable id)sender
{
    if (self.viewItem == nil) {
        return NO;
    }

    // Already in detail view, so no link to "info"
    if (action == self.viewItem.metadataActionSelector) {
        return NO;
    }
    return [self.viewItem canPerformAction:action];
}

- (void)copyMediaAction:(nullable id)sender
{
    if (!self.viewItem) {
        OWSFail(@"copy should only be available when a viewItem is present");
        return;
    }

    [self.viewItem copyMediaAction];
}

- (void)shareMediaAction:(nullable id)sender
{
    if (!self.viewItem) {
        OWSFail(@"share should only be available when a viewItem is present");
        return;
    }

    [self didPressShare:sender];
}

- (void)saveMediaAction:(nullable id)sender
{
    if (!self.viewItem) {
        OWSFail(@"save should only be available when a viewItem is present");
        return;
    }

    [self.viewItem saveMediaAction];
}

- (void)deleteAction:(nullable id)sender
{
    if (!self.viewItem) {
        OWSFail(@"delete should only be available when a viewItem is present");
        return;
    }

    [self didPressDelete:sender];
}

- (void)didPressPlayBarButton:(id)sender
{
    OWSAssert(self.isVideo);
    OWSAssert(self.videoPlayer);
    [self playVideo];
}

- (void)didPressPauseBarButton:(id)sender
{
    OWSAssert(self.isVideo);
    OWSAssert(self.videoPlayer);
    [self pauseVideo];
}

#pragma mark - UIScrollViewDelegate

- (nullable UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView
{
    return self.mediaView;
}

- (void)centerMediaViewConstraints
{
    OWSAssert(self.scrollView);

    CGSize scrollViewSize = self.scrollView.bounds.size;
    CGSize imageViewSize = self.mediaView.frame.size;

    CGFloat yOffset = MAX(0, (scrollViewSize.height - imageViewSize.height) / 2);
    self.mediaViewTopConstraint.constant = yOffset;
    self.mediaViewBottomConstraint.constant = yOffset;

    CGFloat xOffset = MAX(0, (scrollViewSize.width - imageViewSize.width) / 2);
    self.mediaViewLeadingConstraint.constant = xOffset;
    self.mediaViewTrailingConstraint.constant = xOffset;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView
{
    [self centerMediaViewConstraints];
    [self.view layoutIfNeeded];
}

- (void)resetMediaFrame
{
    // HACK: Setting the frame to itself *seems* like it should be a no-op, but
    // it ensures the content is drawn at the right frame. In particular I was
    // reproducibly seeing some images squished (they were EXIF rotated, maybe
    // related). similar to this report:
    // https://stackoverflow.com/questions/27961884/swift-uiimageview-stretched-aspect
    [self.view layoutIfNeeded];
    self.mediaView.frame = self.mediaView.frame;
}

#pragma mark - Video Playback

- (void)playVideo
{
    OWSAssert(self.videoPlayer);

    self.playVideoButton.hidden = YES;

    [self.videoPlayer play];

    [self.delegate mediaDetailViewController:self isPlayingVideo:YES];
}

- (void)pauseVideo
{
    OWSAssert(self.isVideo);
    OWSAssert(self.videoPlayer);

    [self.videoPlayer pause];

    [self.delegate mediaDetailViewController:self isPlayingVideo:NO];
}

- (void)stopVideo
{
    OWSAssert(self.isVideo);
    OWSAssert(self.videoPlayer);

    [self.videoPlayer stop];

    self.playVideoButton.hidden = NO;

    [self.delegate mediaDetailViewController:self isPlayingVideo:NO];
}

#pragma mark - OWSVideoPlayer

- (void)videoPlayerDidPlayToCompletion:(OWSVideoPlayer *)videoPlayer
{
    OWSAssert(self.isVideo);
    OWSAssert(self.videoPlayer);
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);

    [self stopVideo];
}

#pragma mark - PlayerProgressBarDelegate

- (void)playerProgressBarDidStartScrubbing:(PlayerProgressBar *)playerProgressBar
{
    OWSAssert(self.videoPlayer);
    [self.videoPlayer pause];
}

- (void)playerProgressBar:(PlayerProgressBar *)playerProgressBar scrubbedToTime:(CMTime)time
{
    OWSAssert(self.videoPlayer);
    [self.videoPlayer seekToTime:time];
}

- (void)playerProgressBar:(PlayerProgressBar *)playerProgressBar
    didFinishScrubbingAtTime:(CMTime)time
        shouldResumePlayback:(BOOL)shouldResumePlayback
{
    OWSAssert(self.videoPlayer);
    [self.videoPlayer seekToTime:time];

    if (shouldResumePlayback) {
        [self.videoPlayer play];
    }
}

#pragma mark - Saving images to Camera Roll

- (void)image:(UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(void *)contextInfo
{
    if (error) {
        DDLogWarn(@"There was a problem saving <%@> to camera roll from %s ",
            error.localizedDescription,
            __PRETTY_FUNCTION__);
    }
}

@end

NS_ASSUME_NONNULL_END
