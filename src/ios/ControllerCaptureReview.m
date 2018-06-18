
#import "FusionResult.h"
#import "FusionPlugin.h"
#import "ControllerCaptureReview.h"
#import "ControllerImagePreview.h"
#import "MaterialActivityIndicator.h"

@implementation ControllerCaptureReview {
  UIAlertController* alertController;
  MDCActivityIndicator* waitIndicator;
  UILabel* waitLabel;
  UIView* waitCover;
  UIView* decisionModal;
  NSTimer* loadingTimer;
  BOOL initializedSeekbar;
  BOOL hasExercisesRemaining;
}

-(id) initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  return self;
}

-(void) initSeekbar {
  AVPlayer* player = self.moviePlayer.player;
  AVPlayerItem* playerItem = [player currentItem];
  CMTime duration = [playerItem.asset duration];
  if (CMTIME_IS_INVALID(duration)) {
      return;
  }
  
  double seconds = CMTimeGetSeconds(duration);
  if (isfinite(seconds)) {
    initializedSeekbar = YES;
    __weak id weakSelf = self;

    id exerciseVideoUrl = [[self.plugin exercise] videoUrl];
    [self.slider setHidden:(exerciseVideoUrl == nil)];
    [self.playbackButton setSelected:(exerciseVideoUrl != nil)];
    [self.playbackButton setHidden:NO];
    
    CGFloat seekbarWidth = CGRectGetWidth([self.slider bounds]);
    double interval = (0.5 * (seconds / seekbarWidth));
    
    CMTime seekbarSeconds = CMTimeMakeWithSeconds(interval, NSEC_PER_SEC);
    seekbarObserver = [player addPeriodicTimeObserverForInterval:seekbarSeconds queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
      [weakSelf seekbarSync];
    }];
  }
}

-(IBAction) cancel:(id)sender forEvent:(UIEvent *)event {
  alertController = [UIAlertController alertControllerWithTitle:@"Warning" message:@"You are about to leave this section of the test and will lose any data." preferredStyle:UIAlertControllerStyleAlert];
  [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
    [self.plugin cancelled];
  }]];
  [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleDefault handler:nil]];
  
  [self presentViewController:alertController animated:YES completion:nil];
}

-(IBAction) retakeVideo:(id)sender forEvent:(UIEvent *)event {
  ControllerCaptureOverlay* parent = (ControllerCaptureOverlay*)self.parentViewController;
  [parent retakeVideo:self forMovie:[self.plugin currentVideoUrl]];
}

-(IBAction) saveVideo:(id)sender forEvent:(UIEvent *)event {
  [self ensureWaitCover];
  [self ensureWaitIndicator];

  NSString* boundary = @"FfD04x";
  FusionExercise* exercise = [self.plugin exercise];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^(void) {
    NSData* file = [NSData dataWithContentsOfURL:[self.plugin currentVideoUrl]];
    NSData* payload = [self generateFileUploadData:boundary data:file parameters:@{
      @"filename": [NSString stringWithFormat:@"%@-video.mp4", [exercise filePrefix]],
      @"testId": [exercise testId],
      @"testTypeId": [exercise testTypeId],
      @"uniqueId": [exercise uniqueId],
      @"version": [exercise version],
      @"viewId": [exercise viewId],
      @"exerciseId": [exercise exerciseId],
      @"bodySideId": [exercise bodySideId],
      @"exerciseName": [exercise name]
    }];

    NSString* payloadLength = [NSString stringWithFormat:@"%lu", (unsigned long)[payload length]];
    NSMutableURLRequest* request = [[NSMutableURLRequest alloc] initWithURL:[self.plugin uploadEndpointUrl] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:300];
    [request setHTTPMethod:@"POST"];
    if ([self.plugin apiVersion])
      [request setValue:[self.plugin apiVersion] forHTTPHeaderField:@"X-Api-Version"];
    if ([self.plugin apiAuthorize])
      [request setValue:[self.plugin apiAuthorize] forHTTPHeaderField:@"Authorization"];
    [request setValue:payloadLength forHTTPHeaderField:@"Content-Length"];
    [request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary] forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:payload];
    
    NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    NSURLSession* session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:NSOperationQueue.mainQueue];
    
    NSURLSessionTask* task = [session dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
      if (error.code != noErr) {
        if (error.code == NSURLErrorTimedOut) {
          alertController = [UIAlertController alertControllerWithTitle:@"Video Upload Timeout" message:@"Video is taking too long to upload. This may be due to a slow or low bandwidth connection. Check your connection and try again later." preferredStyle:UIAlertControllerStyleAlert];
          [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self.plugin failed:@"Video upload timed out"];
          }]];

          [self presentViewController:alertController animated:YES completion:nil];
        } else {
          alertController = [UIAlertController alertControllerWithTitle:@"Video Upload Failed" message:@"Unable to make request at this time. Please check your connection and try again later." preferredStyle:UIAlertControllerStyleAlert];
          [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self.plugin failed:@"Video upload request failed"];
          }]];

          [self presentViewController:alertController animated:YES completion:nil];
        }
        return;
      }

      NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
      NSInteger statusCode = [httpResponse statusCode];
      if (statusCode >= 200 && statusCode < 300) {
        NSError* jsonError = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
        if (jsonError.code != noErr) {
          alertController = [UIAlertController alertControllerWithTitle:@"Video Upload was Rejected" message:@"An invalid response was received while the video was being uploaded. Please try again later." preferredStyle:UIAlertControllerStyleAlert];
          [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self.plugin failed:@"Video upload invalid response"];
          }]];

          [self presentViewController:alertController animated:YES completion:nil];
        }

        id haveAllVideos = json[@"HaveAllVideos"];
        hasExercisesRemaining = haveAllVideos ? ![haveAllVideos boolValue] : NO;

        dispatch_async(dispatch_get_main_queue(), ^(void) {
          if (waitIndicator && waitIndicator.isAnimating) {
            [waitIndicator setProgress:1.0];
            [waitLabel setText:@"100%"];
            loadingTimer = [NSTimer scheduledTimerWithTimeInterval:1.15 target:self selector:@selector(uploadingFinishFired:) userInfo:nil repeats:NO];
          } else
            [self uploadingFinishFired:nil];
        });

        return;
      }

      alertController = [UIAlertController alertControllerWithTitle:@"Video Upload was Rejected" message:@"Videos are not being accepted at this time. Please try again later." preferredStyle:UIAlertControllerStyleAlert];
      [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self.plugin failed:@"Video upload rejected"];
      }]];

      [self presentViewController:alertController animated:YES completion:nil];
    }];
    [task resume];
  });
}

-(IBAction) takePicture:(id)sender forEvent:(UIEvent *)event {
  AVPlayer* player = self.moviePlayer.player;
  AVAsset* asset = [[player currentItem] asset];
  CMTime currentTime = [player currentTime];
  
  AVAssetImageGenerator* generator = [[AVAssetImageGenerator alloc] initWithAsset:asset];
  [generator setAppliesPreferredTrackTransform:YES];
  [generator setMaximumSize:CGSizeMake(360, 640)];
  generator.requestedTimeToleranceBefore = kCMTimeZero;
  generator.requestedTimeToleranceAfter = kCMTimeZero;
  
  NSError* error;
  CMTime actualTime;
  CGImageRef imageRef = [generator copyCGImageAtTime:currentTime actualTime:&actualTime error:&error];
  
  if ((error.code != noErr)) {
    alertController = [UIAlertController alertControllerWithTitle:@"Unable to Capture Image" message:[error localizedDescription] preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
      [self.plugin failed:[error localizedDescription]];
    }]];

    [self presentViewController:alertController animated:YES completion:nil];
    return;
  }

  [[self takeButton] setUserInteractionEnabled:NO];
  UIImage* image = [UIImage imageWithCGImage:imageRef];

  CGImageRelease(imageRef);
  AudioServicesPlaySystemSound(1108);
  
  ControllerImagePreview* previewController = [[ControllerImagePreview alloc] initWithNibName:@"ControllerImagePreview" bundle:nil];
  [previewController setPlugin:self.plugin];
  [previewController setMovieTime:[NSNumber numberWithFloat:CMTimeGetSeconds(currentTime)]];
  [previewController setMovieImage:image];
  
  [self addChildViewController:previewController];
  [self.view addSubview:previewController.view];
  [previewController didMoveToParentViewController:self];
  
  CGFloat point = CGRectGetWidth(self.view.frame);
  CGRect frame = self.view.bounds;
  frame.origin.x += point;
  frame.size.width = self.view.frame.size.width;
  frame.size.height = self.view.frame.size.height;
  
  previewController.view.frame = frame;
  [UIView animateWithDuration:0.25f animations:^{previewController.view.frame = self.view.bounds;}];
}

-(IBAction) togglePlayback:(id)sender forEvent:(UIEvent *)event {
  id exerciseVideoUrl = [[self.plugin exercise] videoUrl];
  [self.captureInfoView setHidden:YES];
  [self.saveInfoView setHidden:YES];
  [self.saveButton setHidden:YES];
  [self.takeButton setHidden:YES];
  
  if ([self.playbackButton isSelected]) {
    if (exerciseVideoUrl != nil) {
      [self.captureInfoView setHidden:NO];
      [self.takeButton setHidden:NO];
    } else {
      [self.saveInfoView setHidden:NO];
      [self.saveButton setHidden:NO];
    }

    [self.moviePlayer.player pause];
  } else
    [self.moviePlayer.player play];

  [self.playbackButton setSelected:![self.playbackButton isSelected]];
}

-(IBAction) seekbarAction:(UISlider *)sender forEvent:(UIEvent *)event {
  [[self.captureInfoView layer] setHidden:YES];
  [[self.saveInfoView layer] setHidden:YES];

  AVPlayer* player = self.moviePlayer.player;
  AVPlayerItem* playerItem = [player currentItem];
  CMTime duration = [playerItem.asset duration];

  double seconds = CMTimeGetSeconds(duration);
  float minValue = [sender minimumValue];
  float maxValue = [sender maximumValue];
  float currentValue = [sender value];
  double value = seconds * (currentValue - minValue) / (maxValue - minValue);
  
  CMTime time = CMTimeMakeWithSeconds(value, NSEC_PER_SEC);
  [player seekToTime:time toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

-(IBAction) seekbarPause:(id)sender forEvent:(UIEvent *)event {
  AVPlayer* player = self.moviePlayer.player;
  [player setRate:0.f];

  id exerciseVideoUrl = [[self.plugin exercise] videoUrl];
  if (exerciseVideoUrl != nil)
    [self.takeButton setHidden:NO];
  else
    [self.saveButton setHidden:NO];
  
  [self.playbackButton setSelected:NO];
}

-(void) retakePicture:(UIViewController *)child {
  [[self.captureInfoView layer] setHidden:NO];
  [[self.saveInfoView layer] setHidden:YES];
  [self.saveButton setHidden:YES];
  [self.takeButton setHidden:NO];

  CGFloat point = CGRectGetWidth(child.view.frame);
  CGRect frame = child.view.bounds;
  frame.origin.x += point;
  frame.size.width = child.view.frame.size.width;
  frame.size.height = child.view.frame.size.height;
  
  [UIView animateWithDuration:0.25f delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{child.view.frame = frame;} completion:^(BOOL finished){
    [child willMoveToParentViewController:nil];
    [child.view removeFromSuperview];
    [child removeFromParentViewController];
    [[self takeButton] setUserInteractionEnabled:YES];
  }];
}

-(void) playerReachedEnd:(NSNotification *)notification {
  AVPlayerItem* item = [notification object];
  [item seekToTime:kCMTimeZero];

  id exerciseVideoUrl = [[self.plugin exercise] videoUrl];
  if (exerciseVideoUrl == nil)
    [self.saveButton setHidden:NO];
  else {
    [self.takeButton setHidden:NO];
    [self.captureInfoView setHidden:NO];
  }

  [self.playbackButton setSelected:NO];
}

-(void) observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
  id exerciseVideoUrl = [[self.plugin exercise] videoUrl];
  AVPlayer* player = [self.moviePlayer player];
  AVPlayerItem* playerItem = [player currentItem];

  if (object == player && [keyPath isEqualToString:@"status"]) {
    if (player.status == AVPlayerStatusFailed) {
      alertController = [UIAlertController alertControllerWithTitle:@"Unable to Retrieve Video" message:@"The selected video has failed to load. Please try again later." preferredStyle:UIAlertControllerStyleAlert];
      [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self.plugin failed:@"Unable to retrieve video"];
      }]];
      
      [self presentViewController:alertController animated:YES completion:nil];
      return;
    }

    if (exerciseVideoUrl != nil)
      [self ensureWaitCover];
  }

  if (object == playerItem && [keyPath isEqualToString:@"status"]) {
    if (playerItem.status == AVPlayerItemStatusFailed) {
      alertController = [UIAlertController alertControllerWithTitle:@"Unable to Retrieve Video" message:@"The selected video has failed to load. Please try again later." preferredStyle:UIAlertControllerStyleAlert];
      [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self.plugin failed:@"Unable to retrieve video"];
      }]];
      
      [self presentViewController:alertController animated:YES completion:nil];
      return;
    }
  }

  if (object == playerItem && [keyPath isEqualToString:@"loadedTimeRanges"] && !initializedSeekbar) {
    if (playerItem.status == AVPlayerItemStatusFailed)
      return;
    
    NSArray* ranges = (NSArray *)[change objectForKey:NSKeyValueChangeNewKey];
    if (ranges && [ranges count]) {
      if (loadingTimer) {
        if ([loadingTimer isValid])
          [loadingTimer invalidate];
        loadingTimer = nil;
      }

      CMTime duration = playerItem.asset.duration;
      CMTimeRange range = [[ranges objectAtIndex:0] CMTimeRangeValue];
      float durationSeconds = CMTimeGetSeconds(duration);
      float rangeSeconds = CMTimeGetSeconds(CMTimeAdd(range.start, range.duration));

      if (durationSeconds == rangeSeconds) {
        if ((waitIndicator && waitLabel) && waitIndicator.isAnimating) {
          [waitIndicator setProgress:1.0];
          [waitLabel setText:@"100%"];
          loadingTimer = [NSTimer scheduledTimerWithTimeInterval:1.15 target:self selector:@selector(loadingFinishFired:) userInfo:nil repeats:NO];
        } else
          [self loadingFinishFired:nil];
        return;
      }

      if (waitIndicator && waitLabel) {
        float percentage = ((rangeSeconds / durationSeconds));
        [waitIndicator setProgress:percentage];
        [waitLabel setText:[NSString stringWithFormat:@"%d%%", (int)(percentage * 100)]];

        if (!waitIndicator.isAnimating)
          [waitIndicator startAnimating];
      }
    }
  }
}

-(void) URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)totalBytesSent totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
  dispatch_async(dispatch_get_main_queue(), ^(void) {
    if (waitIndicator && waitLabel) {
      float percentage = ((float)totalBytesSent/(float)totalBytesExpectedToSend);
      if (percentage > 0.98)
        percentage = 0.99;

      [waitIndicator setProgress:percentage];
      [waitLabel setText:[NSString stringWithFormat:@"%d%%", (int)(percentage * 100)]];
      
      if (!waitIndicator.isAnimating)
        [waitIndicator startAnimating];
    }
  });
}

-(void) seekbarSync {
  AVPlayer* player = [self.moviePlayer player];
  AVPlayerItem* playerItem = [player currentItem];
  CMTime duration = [playerItem.asset duration];
  
  if (CMTIME_IS_INVALID(duration)) {
    self.slider.minimumValue = 0.0;
    return;
  }
  
  double seconds = CMTimeGetSeconds(duration);
  double currentSeconds = CMTimeGetSeconds([player currentTime]);
  
  float minValue = [self.slider minimumValue];
  float maxValue = [self.slider maximumValue];
  [self.slider setValue:(maxValue - minValue) * currentSeconds/seconds + minValue];
}

-(void) ensureWaitCover {
  if (waitCover)
    return;

  waitCover = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  [waitCover setBackgroundColor:[[UIColor blackColor] colorWithAlphaComponent:0.65]];
  [self.view addSubview:waitCover];
}

-(void) ensureWaitIndicator {
  if (waitIndicator && waitLabel)
    return;

  CGRect bounds = self.view.bounds;
  CGSize size = bounds.size;
  CGPoint center = CGPointMake(size.width / 2, size.height / 3);

  waitIndicator = [[MDCActivityIndicator alloc] init];
  [waitIndicator setRadius:44.0];
  [waitIndicator setStrokeWidth:7.0];
  [waitIndicator setIndicatorMode:MDCActivityIndicatorModeDeterminate];
  [waitIndicator setCycleColors:@[]];
  [waitIndicator setCenter:center];

  waitLabel = [[UILabel alloc] initWithFrame:bounds];
  [waitLabel setFont:[UIFont systemFontOfSize:22.0 weight:UIFontWeightSemibold]];
  [waitLabel setTextColor:UIColor.whiteColor];
  [waitLabel setTextAlignment:NSTextAlignmentCenter];
  [waitLabel setCenter:center];

  [self ensureWaitCover];
  [waitCover addSubview:waitIndicator];
  [waitCover addSubview:waitLabel];
}

-(void) ensureDecisionModal {
  CGRect mainBounds = [[UIScreen mainScreen] bounds];
  CGSize mainSize = mainBounds.size;
  CGRect modalBounds = CGRectMake(0, 0, mainSize.width - 50, 275);
  if (modalBounds.size.width > 350)
    modalBounds = CGRectMake(0, 0, 350, 275);

  CGSize modalSize = modalBounds.size;
  float modalWidth = modalSize.width;
  float modalHeight = modalSize.height;

  decisionModal = [[UIView alloc] initWithFrame:modalBounds];
  [decisionModal setCenter:CGPointMake(mainSize.width / 2, mainSize.height / 2)];
  [decisionModal setBackgroundColor:UIColor.whiteColor];
  [decisionModal setAutoresizingMask:(
    UIViewAutoresizingFlexibleWidth |
    UIViewAutoresizingFlexibleLeftMargin |
    UIViewAutoresizingFlexibleRightMargin |
    UIViewAutoresizingFlexibleTopMargin |
    UIViewAutoresizingFlexibleBottomMargin)];
  [[decisionModal layer] setCornerRadius:12];

  UILabel* savedLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 25, modalWidth, 50)];
  [savedLabel setText:@"Video Saved"];
  [savedLabel setTextColor:UIColorWithHexString(@"#41baec")];
  [savedLabel setTextAlignment:NSTextAlignmentCenter];
  [savedLabel setFont:[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1]];
  
  UILabel* orLabel = [[UILabel alloc] initWithFrame:CGRectMake((modalWidth/2 - 20), modalHeight - 120, 40, 40)];
  [orLabel setText:@"OR"];
  [orLabel setTextColor:UIColorWithHexString(@"#dfdfdf")];
  [orLabel setFont:[UIFont systemFontOfSize:(orLabel.font.pointSize - 2)]];
  [orLabel setTextAlignment:NSTextAlignmentCenter];
  [orLabel setBackgroundColor:UIColor.whiteColor];
  
  UIView* orLine = [[UIView alloc] initWithFrame:CGRectMake(15, modalHeight - 100, modalWidth - 30, 2)];
  [orLine setBackgroundColor:UIColorWithHexString(@"#dfdfdf")];
  
  UIButton* nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [nextButton addTarget:self action:@selector(continueToNextExercise) forControlEvents:UIControlEventTouchUpInside];
  [nextButton setFrame:CGRectMake(15, modalHeight - 180, modalWidth - 30, 60)];
  [nextButton setBackgroundColor:UIColorWithHexString(@"#00b96d")];
  [nextButton setTitle:(hasExercisesRemaining ? @"RECORD ANOTHER EXERCISE" : @"BACK TO TESTS") forState:UIControlStateNormal];
  [nextButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  [[nextButton titleLabel] setFont:[UIFont boldSystemFontOfSize:([nextButton titleLabel].font.pointSize - 1)]];
  [[nextButton layer] setCornerRadius:8];
  
  UIButton* markButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [markButton addTarget:self action:@selector(continueToMarkExercise) forControlEvents:UIControlEventTouchUpInside];
  [markButton setFrame:CGRectMake(15, modalHeight - 80, modalWidth - 30, 60)];
  [markButton setBackgroundColor:UIColorWithHexString(@"#41baec")];
  [markButton setTitle:@"CAPTURE AND PLACE MARKERS" forState:UIControlStateNormal];
  [markButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
  [[markButton titleLabel] setFont:[UIFont boldSystemFontOfSize:([markButton titleLabel].font.pointSize - 1)]];
  [[markButton layer] setCornerRadius:8];

  [self ensureWaitCover];
  [waitCover addSubview:decisionModal];
  [decisionModal addSubview:savedLabel];
  [decisionModal addSubview:nextButton];
  [decisionModal addSubview:markButton];
  [decisionModal addSubview:orLine];
  [decisionModal addSubview:orLabel];
}

-(void) unloadWaiting {
  [self unloadWaitIndicator];
  [self unloadDecisionModal];
  [self unloadWaitCover];
}

-(void) unloadWaitCover {
  if (!waitCover)
    return;

  [waitCover removeFromSuperview];
  waitCover = nil;
}

-(void) unloadWaitIndicator {
  if (!waitIndicator || !waitLabel)
    return;

  if (waitIndicator.isAnimating) {
    [waitIndicator stopAnimating];
    [waitLabel setHidden:YES];
  }

  [waitIndicator removeFromSuperview];
  [waitLabel removeFromSuperview];
  waitIndicator = nil;
  waitLabel = nil;
}

-(void) unloadDecisionModal {
  if (!decisionModal)
    return;

  [[decisionModal subviews] makeObjectsPerformSelector:@selector(removeFromSuperview)];
  [decisionModal removeFromSuperview];
  decisionModal = nil;
}

-(NSData *) generateFileUploadData:(NSString *)boundary data:(NSData *)data parameters:(NSDictionary *)parameters {
  NSMutableData* payload = [NSMutableData alloc];
  [parameters enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSObject* value, BOOL* stop) {
    if (![key isEqual:@"filename"] && value && ![value isEqual:[NSNull null]]) {
      [payload appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
      [payload appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
      [payload appendData:[[NSString stringWithFormat:@"%@\r\n", value] dataUsingEncoding:NSUTF8StringEncoding]];
    }
  }];
  
  [payload appendData:[[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  [payload appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"upload[file]\"; filename=\"%@\"\r\n", parameters[@"filename"]] dataUsingEncoding:NSUTF8StringEncoding]];
  [payload appendData:[@"Content-Type: application/octet-stream\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  [payload appendData:[@"Content-Transfer-Encoding: binary\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  [payload appendData:data];
  [payload appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  [payload appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
  return payload;
}

-(void) continueToNextExercise {
  [self unloadDecisionModal];
  [self unloadWaitCover];
  
  FusionResult* result = [[FusionResult alloc] init];
  [result setCapturedImage:NO];
  [result setCapturedVideo:YES];
  [result setVideoUrl:[self.plugin currentVideoUrl]];
  [self.plugin captured:result];
}

-(void) continueToMarkExercise {
  [self unloadDecisionModal];
  [self unloadWaitCover];

  [self.captureInfoView setHidden:YES];
  [self.saveInfoView setHidden:YES];
  [self.saveButton setHidden:YES];
  [self.takeButton setHidden:YES];
  [self.retakeButton setHidden:YES];
  
  [self initSeekbar];
  [self.moviePlayer.player play];
}

-(void) loadingBeginFired:(NSTimer *)timer {
  if ([loadingTimer isValid])
    [loadingTimer invalidate];
  loadingTimer = nil;
  
  [self ensureWaitCover];
  [self ensureWaitIndicator];
  
  if (!waitIndicator.isAnimating) {
    [waitIndicator setProgress:0.0];
    [waitIndicator startAnimating];
    [waitLabel setHidden:NO];
    [waitLabel setText:@"0%"];
  }
}

-(void) loadingFinishFired:(NSTimer *)timer {
  if ([loadingTimer isValid])
    [loadingTimer invalidate];
  loadingTimer = nil;
  
  [self unloadWaiting];
  [self initSeekbar];

  id exerciseVideoUrl = [[self.plugin exercise] videoUrl];
  if (exerciseVideoUrl != nil)
    [self.moviePlayer.player play];
  else {
    [self.saveInfoView setHidden:NO];
    [self.saveButton setHidden:NO];
    [self.retakeButton setHidden:NO];
  }
}

-(void) uploadingFinishFired:(NSTimer *)timer {
  dispatch_async(dispatch_get_main_queue(), ^(void) {
    if ([loadingTimer isValid])
      [loadingTimer invalidate];
    loadingTimer = nil;
    
    [[self.plugin exercise] setVideoUrl:[self.plugin currentVideoUrl]];
    [self.captureInfoView setHidden:YES];
    [self.saveInfoView setHidden:YES];
    [self.saveButton setHidden:YES];
    [self.takeButton setHidden:YES];
    [self.retakeButton setHidden:YES];
    
    [self unloadWaitIndicator];
    [self ensureDecisionModal];
  });
}

-(void) viewDidLoad {
  [super viewDidLoad];
  [[self.captureInfoView layer] setCornerRadius:8];
  [[self.saveInfoView layer] setCornerRadius:8];

  if ([self.plugin currentVideoUrl] == nil)
    return;

  loadingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(loadingBeginFired:) userInfo:nil repeats:NO];
  AVPlayer* player = [AVPlayer playerWithURL:[self.plugin currentVideoUrl]];
  AVPlayerItem* playerItem = [player currentItem];
  player.automaticallyWaitsToMinimizeStalling = YES;
  player.actionAtItemEnd = AVPlayerActionAtItemEndPause;
  player.muted = YES;
  
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerReachedEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:[player currentItem]];
  [player addObserver:self forKeyPath:@"status" options:0 context:nil];
  [playerItem addObserver:self forKeyPath:@"status" options:0 context:nil];
  [playerItem addObserver:self forKeyPath:@"loadedTimeRanges" options:NSKeyValueObservingOptionNew context:nil];
  
  self.moviePlayer = [[AVPlayerViewController alloc] init];
  self.moviePlayer.allowsPictureInPicturePlayback = NO;
  self.moviePlayer.showsPlaybackControls = NO;
  self.moviePlayer.player = player;
  [self.slider setMinimumValue:0.0];
  [self.slider setValue:0.0];
  initializedSeekbar = NO;
}

-(void) viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [[UIDevice currentDevice] setValue:[NSNumber numberWithInteger:UIInterfaceOrientationPortrait] forKey:@"orientation"];
  
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.playerView setBackgroundColor:UIColor.blackColor];
    [self.playerView addSubview:self.moviePlayer.view];
    
    [self.slider setHidden:YES];
    [self.saveInfoView setHidden:YES];
    [self.captureInfoView setHidden:YES];
    [self.saveButton setHidden:YES];
    [self.takeButton setHidden:YES];
    [self.retakeButton setHidden:YES];
    [self.playbackButton setSelected:YES];

    if ([self.plugin currentVideoUrl] == nil) {
      alertController = [UIAlertController alertControllerWithTitle:@"Invalid Video" message:@"The selected video is either corrupt or missing." preferredStyle:UIAlertControllerStyleAlert];
      [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self.plugin failed:@"Invalid video"];
      }]];

      [self presentViewController:alertController animated:YES completion:nil];
    }
  });
}

-(void) viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
    
  [self.playerView layoutIfNeeded];
  self.moviePlayer.view.frame = self.playerView.bounds;
}

-(void) viewWillDisappear:(BOOL)animated {
  AVPlayer* player = [self.moviePlayer player];
  AVPlayerItem* playerItem = [player currentItem];
  [player removeTimeObserver:seekbarObserver];
  [player removeObserver:self forKeyPath:@"status"];
  [playerItem removeObserver:self forKeyPath:@"status"];
  [playerItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
  alertController = nil;
  
  [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
  [super viewWillDisappear:animated];
}

-(void) didReceiveMemoryWarning {
  alertController = [UIAlertController alertControllerWithTitle:@"Unable to Capture Video" message:@"It appears you are running low on memory. Try closing a few applications. Make sure you have enough space to record a movie or video." preferredStyle:UIAlertControllerStyleAlert];
  [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
    [self.plugin failed:@"Low memory warning"];
  }]];

  [self presentViewController:alertController animated:YES completion:nil];
  [super didReceiveMemoryWarning];
}

-(BOOL) prefersStatusBarHidden {
  return YES;
}

-(BOOL) shouldAutorotate {
  return NO;
}

-(UIInterfaceOrientation) preferredInterfaceOrientationForPresentation {
  return UIInterfaceOrientationPortrait;
}

-(UIInterfaceOrientationMask) supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskPortrait;
}

-(UIViewController *) childViewControllerForStatusBarHidden {
  return nil;
}

static UIColor* UIColorWithHexString(NSString* hex) {
  unsigned int rgb = 0;
  [[NSScanner scannerWithString:
    [[hex uppercaseString] stringByTrimmingCharactersInSet:
     [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet]]] scanHexInt:&rgb];
  return [UIColor colorWithRed:((CGFloat)((rgb & 0xFF0000) >> 16)) / 255.0
                         green:((CGFloat)((rgb & 0xFF00) >> 8)) / 255.0
                          blue:((CGFloat)(rgb & 0xFF)) / 255.0
                         alpha:1.0];
}

@end
