/*

    File: aurioTouchAppDelegate.mm
Abstract: n/a
 Version: 1.11

Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
Inc. ("Apple") in consideration of your agreement to the following
terms, and your use, installation, modification or redistribution of
this Apple software constitutes acceptance of these terms.  If you do
not agree with these terms, please do not use, install, modify or
redistribute this Apple software.

In consideration of your agreement to abide by the following terms, and
subject to these terms, Apple grants you a personal, non-exclusive
license, under Apple's copyrights in this original Apple software (the
"Apple Software"), to use, reproduce, modify and redistribute the Apple
Software, with or without modifications, in source and/or binary forms;
provided that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the following
text and disclaimers in all such redistributions of the Apple Software.
Neither the name, trademarks, service marks or logos of Apple Inc. may
be used to endorse or promote products derived from the Apple Software
without specific prior written permission from Apple.  Except as
expressly stated in this notice, no other rights or licenses, express or
implied, are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or by other
works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

Copyright (C) 2009 Apple Inc. All Rights Reserved.


*/

#import "aurioTouchAppDelegate.h"
#import "AudioUnit/AudioUnit.h"
#import "CAXException.h"

@implementation aurioTouchAppDelegate

// value, a, r, g, b
GLfloat colorLevels[] = {
0., 1., 0., 0., 0., 
.333, 1., .7, 0., 0., 
.667, 1., 0., 0., 1., 
1., 1., 0., 1., 1., 
};

@synthesize window;
@synthesize view;

@synthesize rioUnit;
@synthesize unitIsRunning;
@synthesize displayMode;
@synthesize fftBufferManager;
@synthesize mute;
@synthesize inputProc;

#pragma mark-

CGPathRef CreateRoundedRectPath(CGRect RECT, CGFloat cornerRadius)
{
	CGMutablePathRef		path;
	path = CGPathCreateMutable();
	
	double		maxRad = MAX(CGRectGetHeight(RECT) / 2., CGRectGetWidth(RECT) / 2.);
	
	if (cornerRadius > maxRad) cornerRadius = maxRad;
	
	CGPoint		bl, tl, tr, br;
	
	bl = tl = tr = br = RECT.origin;
	tl.y += RECT.size.height;
	tr.y += RECT.size.height;
	tr.x += RECT.size.width;
	br.x += RECT.size.width;
	
	CGPathMoveToPoint(path, NULL, bl.x + cornerRadius, bl.y);
	CGPathAddArcToPoint(path, NULL, bl.x, bl.y, bl.x, bl.y + cornerRadius, cornerRadius);
	CGPathAddLineToPoint(path, NULL, tl.x, tl.y - cornerRadius);
	CGPathAddArcToPoint(path, NULL, tl.x, tl.y, tl.x + cornerRadius, tl.y, cornerRadius);
	CGPathAddLineToPoint(path, NULL, tr.x - cornerRadius, tr.y);
	CGPathAddArcToPoint(path, NULL, tr.x, tr.y, tr.x, tr.y - cornerRadius, cornerRadius);
	CGPathAddLineToPoint(path, NULL, br.x, br.y + cornerRadius);
	CGPathAddArcToPoint(path, NULL, br.x, br.y, br.x - cornerRadius, br.y, cornerRadius);
	
	CGPathCloseSubpath(path);
	
	CGPathRef				ret;
	ret = CGPathCreateCopy(path);
	CGPathRelease(path);
	return ret;
}

#pragma mark -Audio Session Interruption Listener

void rioInterruptionListener(void *inClientData, UInt32 inInterruption)
{
	printf("Session interrupted! --- %s ---", inInterruption == kAudioSessionBeginInterruption ? "Begin Interruption" : "End Interruption");
	
	aurioTouchAppDelegate *THIS = (aurioTouchAppDelegate*)inClientData;
	
	if (inInterruption == kAudioSessionEndInterruption) {
		// make sure we are again the active session
		AudioSessionSetActive(true);
		AudioOutputUnitStart(THIS->rioUnit);
	}
	
	if (inInterruption == kAudioSessionBeginInterruption) {
		AudioOutputUnitStop(THIS->rioUnit);
    }
}

#pragma mark -Audio Session Property Listener

void propListener(	void *                  inClientData,
					AudioSessionPropertyID	inID,
					UInt32                  inDataSize,
					const void *            inData)
{
	aurioTouchAppDelegate *THIS = (aurioTouchAppDelegate*)inClientData;
	if (inID == kAudioSessionProperty_AudioRouteChange)
	{
		try {
			// if there was a route change, we need to dispose the current rio unit and create a new one
			XThrowIfError(AudioComponentInstanceDispose(THIS->rioUnit), "couldn't dispose remote i/o unit");		

			SetupRemoteIO(THIS->rioUnit, THIS->inputProc, THIS->thruFormat);
			
			UInt32 size = sizeof(THIS->hwSampleRate);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &THIS->hwSampleRate), "couldn't get new sample rate");

			XThrowIfError(AudioOutputUnitStart(THIS->rioUnit), "couldn't start unit");
						
			// we need to rescale the sonogram view's color thresholds for different input
			CFStringRef newRoute;
			size = sizeof(CFStringRef);
			XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute, &size, &newRoute), "couldn't get new audio route");
			if (newRoute)
			{	
				CFShow(newRoute);
				if (CFStringCompare(newRoute, CFSTR("Headset"), NULL) == kCFCompareEqualTo) // headset plugged in
				{
					colorLevels[0] = .3;				
					colorLevels[5] = .5;
				}
				else if (CFStringCompare(newRoute, CFSTR("Receiver"), NULL) == kCFCompareEqualTo) // headset plugged in
				{
					colorLevels[0] = 0;
					colorLevels[5] = .333;
					colorLevels[10] = .667;
					colorLevels[15] = 1.0;
					
				}			
				else
				{
					colorLevels[0] = 0;
					colorLevels[5] = .333;
					colorLevels[10] = .667;
					colorLevels[15] = 1.0;
					
				}
			}
		} catch (CAXException e) {
			char buf[256];
			fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		}
		
	}
}

#pragma mark -RIO Render Callback

static OSStatus	PerformThru(
							void						*inRefCon, 
							AudioUnitRenderActionFlags 	*ioActionFlags, 
							const AudioTimeStamp 		*inTimeStamp, 
							UInt32 						inBusNumber, 
							UInt32 						inNumberFrames, 
							AudioBufferList 			*ioData)
{
	aurioTouchAppDelegate *THIS = (aurioTouchAppDelegate *)inRefCon;
	OSStatus err = AudioUnitRender(THIS->rioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData);
	if (err) { printf("PerformThru: error %d\n", (int)err); return err; }
	
	// Remove DC component
	for(UInt32 i = 0; i < ioData->mNumberBuffers; ++i)
		THIS->dcFilter[i].InplaceFilter((SInt32*)(ioData->mBuffers[i].mData), inNumberFrames, 1);
	
	if (THIS->fftBufferManager == NULL) return noErr;
	
	if (THIS->fftBufferManager->NeedsNewAudioData())
	{
		THIS->fftBufferManager->GrabAudioData(ioData); 
	}
	
	if (THIS->mute == YES) { SilenceData(ioData); }
	
	return err;
}

#pragma mark-

- (void)applicationDidFinishLaunching:(UIApplication *)application
{	
	// Turn off the idle timer, since this app doesn't rely on constant touch input
	application.idleTimerDisabled = YES;
	
	// mute should be on at launch
	self.mute = YES;
	displayMode = aurioTouchDisplayModeOscilloscopeFFT;
	
	// Initialize our remote i/o unit
	
	inputProc.inputProc = PerformThru;
	inputProc.inputProcRefCon = self;

	CFURLRef url = NULL;
	try {	
		url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, CFStringRef([[NSBundle mainBundle] pathForResource:@"button_press" ofType:@"caf"]), kCFURLPOSIXPathStyle, false);
		XThrowIfError(AudioServicesCreateSystemSoundID(url, &buttonPressSound), "couldn't create button tap alert sound");
		CFRelease(url);
		
		// Initialize and configure the audio session
		XThrowIfError(AudioSessionInitialize(NULL, NULL, rioInterruptionListener, self), "couldn't initialize audio session");
		XThrowIfError(AudioSessionSetActive(true), "couldn't set audio session active\n");
			
		UInt32 audioCategory = kAudioSessionCategory_PlayAndRecord;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(audioCategory), &audioCategory), "couldn't set audio category");
		XThrowIfError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange, propListener, self), "couldn't set property listener");
			
		Float32 preferredBufferSize = .005;
		XThrowIfError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize), "couldn't set i/o buffer duration");
		
		UInt32 size = sizeof(hwSampleRate);
		XThrowIfError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate, &size, &hwSampleRate), "couldn't get hw sample rate");
		
		XThrowIfError(SetupRemoteIO(rioUnit, inputProc, thruFormat), "couldn't setup remote i/o unit");
		
		dcFilter = new DCRejectionFilter[thruFormat.NumberChannels()];

		UInt32 maxFPS;
		size = sizeof(maxFPS);
		XThrowIfError(AudioUnitGetProperty(rioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFPS, &size), "couldn't get the remote I/O unit's max frames per slice");

		printf("maxFramesPerSlice == %lu\n", maxFPS);	/* logan */
		
		fftBufferManager = new FFTBufferManager(maxFPS);
		l_fftData = new int32_t[maxFPS/2];
		
		oscilLine = (GLfloat*)malloc(drawBufferLen * 2 * sizeof(GLfloat));

		XThrowIfError(AudioOutputUnitStart(rioUnit), "couldn't start remote i/o unit");

		size = sizeof(thruFormat);
		XThrowIfError(AudioUnitGetProperty(rioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &thruFormat, &size), "couldn't get the remote I/O unit's output client format");
		
		unitIsRunning = 1;
	}
	catch (CAXException &e) {
		char buf[256];
		fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
		if (url) CFRelease(url);
	}
	catch (...) {
		fprintf(stderr, "An unknown error occurred\n");
		unitIsRunning = 0;
		if (dcFilter) delete[] dcFilter;
		if (url) CFRelease(url);
	}
	
	// Set ourself as the delegate for the EAGLView so that we get drawing and touch events
	view.delegate = self;
	
	// Enable multi touch so we can handle pinch and zoom in the oscilloscope
	view.multipleTouchEnabled = YES;
	
	// Set up our overlay view that pops up when we are pinching/zooming the oscilloscope
	UIImage *img_ui = nil;
	{
		// Draw the rounded rect for the bg path using this convenience function
		CGPathRef bgPath = CreateRoundedRectPath(CGRectMake(0, 0, 234, 110), 15.);
		
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		// Create the bitmap context into which we will draw
		CGContextRef cxt = CGBitmapContextCreate(NULL, 234, 110, 8, 4*234, cs, kCGImageAlphaPremultipliedFirst);
		CGContextSetFillColorSpace(cxt, cs);
		CGFloat fillClr[] = {0., 0., 0., 0.7};
		CGContextSetFillColor(cxt, fillClr);
		// Add the rounded rect to the context...
		CGContextAddPath(cxt, bgPath);
		// ... and fill it.
		CGContextFillPath(cxt);
		
		// Make a CGImage out of the context
		CGImageRef img_cg = CGBitmapContextCreateImage(cxt);
		// Make a UIImage out of the CGImage
		img_ui = [UIImage imageWithCGImage:img_cg];
		
		// Clean up
		CGImageRelease(img_cg);
		CGColorSpaceRelease(cs);
		CGContextRelease(cxt);
		CGPathRelease(bgPath);
	}
	
	// Create the image view to hold the background rounded rect which we just drew
	sampleSizeOverlay = [[UIImageView alloc] initWithImage:img_ui];
	sampleSizeOverlay.frame = CGRectMake(43, 124, 234, 110);
	
	// Create the text view which shows the size of our oscilloscope window as we pinch/zoom
	sampleSizeText = [[UILabel alloc] initWithFrame:CGRectMake(0, -62, 234, 234)];
	sampleSizeText.textAlignment = UITextAlignmentCenter;
	sampleSizeText.textColor = [UIColor whiteColor];
	sampleSizeText.text = @"no mic";
	sampleSizeText.font = [UIFont boldSystemFontOfSize:36.];
	sampleSizeText.backgroundColor = [UIColor clearColor];
	
	// Add the text view as a subview of the overlay BG
	[sampleSizeOverlay addSubview:sampleSizeText];
	// Text view was retained by the above line, so we can release it now
	[sampleSizeText release];
	// Add the overlay view as a subview of the main view
	[view addSubview:sampleSizeOverlay];
	
	// Set up the view to refresh at 20 hz
	[view setAnimationInterval:1./20.];
	[view startAnimation];
}


- (void)dealloc
{	
	delete[] dcFilter;
	delete fftBufferManager;
	
	[view release];
	[window release];
	
	free(oscilLine);

	[super dealloc];
}


- (void)setFFTData:(int32_t *)FFTDATA length:(NSUInteger)LENGTH
{
	if (LENGTH != fftLength)
	{
		fftLength = LENGTH;
		fftData = (SInt32 *)(realloc(fftData, LENGTH * sizeof(SInt32)));
	}
	memmove(fftData, FFTDATA, fftLength * sizeof(Float32));
	hasNewFFTData = YES;
}

- (void)clearTextures
{
	bzero(texBitBuffer, sizeof(UInt32) * 512);
	SpectrumLinkedTexture *curTex;
	
	for (curTex = firstTex; curTex; curTex = curTex->nextTex)
	{
		glBindTexture(GL_TEXTURE_2D, curTex->texName);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, texBitBuffer);
	}
}

- (void)drawView:(id)sender forTime:(NSTimeInterval)time
{
	// Clear the view
	glClear(GL_COLOR_BUFFER_BIT);
	
	if (fftBufferManager->HasNewAudioData())
	{
		if (fftBufferManager->ComputeFFT(l_fftData, &fftMajorPitch))
		{
			[self setFFTData:l_fftData length:fftBufferManager->GetNumberFrames() / 2];
		}
		else
			hasNewFFTData = NO;
	}
	
	if (hasNewFFTData) sampleSizeText.text = [NSString stringWithFormat:@"%.2f", fftMajorPitch];
	
	
	glClear(GL_COLOR_BUFFER_BIT);
	
	glEnable(GL_TEXTURE);
	glEnable(GL_TEXTURE_2D);
	
	glPushMatrix();
	glTranslatef(0., 480., 0.);
	glRotatef(-90., 0., 0., 1.);
	glTranslatef(spectrumRect.origin.x + spectrumRect.size.width, spectrumRect.origin.y, 0.);
	
	GLfloat quadCoords[] = {
		0., 0., 
		SPECTRUM_BAR_WIDTH, 0., 
		0., 512., 
		SPECTRUM_BAR_WIDTH, 512., 
	};
	
	GLshort texCoords[] = {
		0, 0, 
		1, 0, 
		0, 1,
		1, 1, 
	};
	
	glVertexPointer(2, GL_FLOAT, 0, quadCoords);
	glEnableClientState(GL_VERTEX_ARRAY);
	glTexCoordPointer(2, GL_SHORT, 0, texCoords);
	glEnableClientState(GL_TEXTURE_COORD_ARRAY);	
	
	glColor4f(1., 1., 1., 1.);
	
	SpectrumLinkedTexture *thisTex;
	glPushMatrix();
	for (thisTex = firstTex; thisTex; thisTex = thisTex->nextTex)
	{
		glTranslatef(-(SPECTRUM_BAR_WIDTH), 0., 0.);
		glBindTexture(GL_TEXTURE_2D, thisTex->texName);
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	glPopMatrix();
	glPopMatrix();
	
	glFlush();
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{
	// display the size of our oscilloscope window in our overlay view
	sampleSizeText.text = [NSString stringWithFormat:@"some Hz"];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
}

@end
