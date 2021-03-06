/*===============================================================================
Copyright (c) 2016 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <sys/time.h>

#import <Vuforia/Vuforia.h>
#import <Vuforia/TrackerManager.h>
#import <Vuforia/State.h>
#import <Vuforia/Tool.h>
#import <Vuforia/ObjectTracker.h>
#import <Vuforia/RotationalDeviceTracker.h>
#import <Vuforia/StateUpdater.h>
#import <Vuforia/Renderer.h>
#import <Vuforia/GLRenderer.h>
#import <Vuforia/DeviceTrackableResult.h>
#include <Vuforia/HeadTransformModel.h>
#include <Vuforia/HandheldTransformModel.h>
#import <Vuforia/Device.h>
#import <Vuforia/CustomViewerParameters.h>
#import <Vuforia/VideoBackgroundConfig.h>
#import <Vuforia/Mesh.h>

#import "ARVREAGLView.h"
#import "Texture.h"
#import "SampleApplicationUtils.h"
#import "SampleApplicationShaderUtils.h"
#import "Teapot.h"
#import "ModelV3d.h"
#include "MathUtils.h"


//******************************************************************************
// *** OpenGL ES thread safety ***
//
// OpenGL ES on iOS is not thread safe.  We ensure thread safety by following
// this procedure:
// 1) Create the OpenGL ES context on the main thread.
// 2) Start the Vuforia camera, which causes Vuforia to locate our EAGLView and start
//    the render thread.
// 3) Vuforia calls our renderFrameVuforia method periodically on the render thread.
//    The first time this happens, the defaultFramebuffer does not exist, so it
//    is created with a call to createFramebuffer.  createFramebuffer is called
//    on the main thread in order to safely allocate the OpenGL ES storage,
//    which is shared with the drawable layer.  The render (background) thread
//    is blocked during the call to createFramebuffer, thus ensuring no
//    concurrent use of the OpenGL ES context.
//
//******************************************************************************


namespace {
    // --- Data private to this unit ---

    const float AR_OBJECT_SCALE_FLOAT = 0.025f;
    const float skyColor[] = {0.4f, 0.5f, 0.6f, 1.0f};
}


@interface ARVREAGLView (PrivateMethods)

- (void)initShaders;
- (void)unloadModels;
- (void)createFramebuffer;
- (void)deleteFramebuffer;
- (void)setFramebuffer;
- (BOOL)presentFramebuffer;
- (float)getSceneScaleFactor;
- (BOOL) prepareViewerDistortionWithTextureSize:(const Vuforia::Vec2I) textureSize;
- (void) renderVideoBackgroundWithViewId:(Vuforia::VIEW) viewId textureUnit:(int) vbVideoTextureUnit viewPort:(Vuforia::Vec4I) viewport;

- (void) renderVRWorldWithDeviceViewPose:(float *) deviceViewPose projectionMatrix:(float *)projectionMatrix;
- (void) renderARWorldWithTargetPose:(float *) targetPose projectionMatrix:(float *) project viewId:(Vuforia::VIEW) viewId viewport:(Vuforia::Vec4I)viewport isARObjectVisible:(bool) isARObjectVisible;
@end


@implementation ARVREAGLView

@synthesize vapp = vapp;

// You must implement this method, which ensures the view's underlying layer is
// of type CAEAGLLayer
+ (Class)layerClass
{
    return [CAEAGLLayer class];
}

- (void)determineContentScaleFactor
{
    UIScreen* mainScreen = [UIScreen mainScreen];
    
    if ([mainScreen respondsToSelector:@selector(nativeScale)]) {
        self.contentScaleFactor = [mainScreen nativeScale];
    }
    else if ([mainScreen respondsToSelector:@selector(displayLinkWithTarget:selector:)] && 2.0 == [UIScreen mainScreen].scale) {
        self.contentScaleFactor = 2.0f;
    }
    else {
        self.contentScaleFactor = 1.0f;
    }
}


//------------------------------------------------------------------------------
#pragma mark - Lifecycle

- (id)initWithFrame:(CGRect)frame appSession:(SampleApplicationSession *) app isStereo:(bool) isStereo isVR:(bool) isVR;
{
    self = [super initWithFrame:frame];
    
    if (self) {
        vapp = app;
        mIsStereo = isStereo;
        mIsVR = isVR;
        
        // Enable retina mode if available on this device
        [self determineContentScaleFactor];
        
        // Create the OpenGL ES context
        context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        
        // The EAGLContext must be set for each thread that wishes to use it.
        // Set it the first time this method is called (on the main thread)
        if (context != [EAGLContext currentContext]) {
            [EAGLContext setCurrentContext:context];
        }
        
        // Initialise the viewer distortion
        glGenTextures(1, &viewerDistortionTextureID);
        glGenTextures(1, &viewerDepthTextureID);
        
        [self initShaders];
    }
    
    return self;
}


- (void)dealloc
{
    [self deleteFramebuffer];
    
    // Tear down context
    if ([EAGLContext currentContext] == context) {
        [EAGLContext setCurrentContext:nil];
    }

}


- (void)finishOpenGLESCommands
{    
    // Called in response to applicationWillResignActive.  The render loop has
    // been stopped, so we now make sure all OpenGL ES commands complete before
    // we (potentially) go into the background
    if (context) {
        [EAGLContext setCurrentContext:context];
        glFinish();
    }
}


- (void)freeOpenGLESResources
{
    // Called in response to applicationDidEnterBackground.  Free easily
    // recreated OpenGL ES resources
    [self deleteFramebuffer];
    glFinish();
}

//------------------------------------------------------------------------------
#pragma mark - UIGLViewProtocol methods

// Draw the current frame using OpenGL
//
// This method is called by Vuforia when it wishes to render the current frame to
// the screen.
//
// *** Vuforia will call this method periodically on a background thread ***
- (void)renderFrameVuforia
{
    if (! vapp.cameraIsStarted) {
        return;
    }
    Vuforia::Renderer& mRenderer = Vuforia::Renderer::getInstance();
    
    [self setFramebuffer];
    
    const Vuforia::State state = Vuforia::TrackerManager::getInstance().getStateUpdater().updateState();
    mRenderer.begin(state);
    
    const Vuforia::RenderingPrimitives renderingPrimitives = Vuforia::Device::getInstance().getRenderingPrimitives();
    Vuforia::ViewList& viewList = renderingPrimitives.getRenderingViews();
    
    // Evaluate targets
    isARObjectVisible = false;
        
    for (int i = 0; i < state.getNumTrackableResults(); i++)
    {
        NSLog(@"Trackable == %d", i);
        const Vuforia::TrackableResult* result = state.getTrackableResult(i);
        Vuforia::Matrix34F trackablePose = result->getPose();
        
        // retrieve device trackable pose
        if (result->isOfType(Vuforia::DeviceTrackableResult::getClassType()))
        {
            deviceViewMatrix = trackablePose;
        }
        else
        {
            interactionViewMatrix = Vuforia::Tool::convertPose2GLMatrix(trackablePose);
            isARObjectVisible = true;
        }
    }
    
    
    // Clear colour and depth buffers
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    
    if(mIsVR && !mIsStereo) {
        glClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    } else {
        glClearColor(0, 0, 0, 1);
    }
    
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    bool distortForViewer = false;
    
    // The 'postprocess' view is a special one that indicates that a distortion postprocess is required
    // If this is present, then we need to prepare an off-screen buffer to support the distortion
    if (viewList.contains(Vuforia::VIEW_POSTPROCESS))
    {
        Vuforia::Vec2I textureSize = renderingPrimitives.getDistortionTextureSize(Vuforia::VIEW_POSTPROCESS);
        distortForViewer = [self prepareViewerDistortionWithTextureSize:textureSize];
    }
        
    // clear the offscreen texture
    if(mIsVR) {
        glClearColor(skyColor[0], skyColor[1], skyColor[2], skyColor[3]);
    } else {
        glClearColor(0, 0, 0, 1);
    }
    glClear(GL_COLOR_BUFFER_BIT);
    
    
    // Iterate over the ViewList
    for (int viewIdx = 0; viewIdx < viewList.getNumViews(); viewIdx++) {
        Vuforia::VIEW vw = viewList.getView(viewIdx);
        
        // Any post processing is a special case that will be completed after
        // the main render loop - so does not imply any rendering here
        if (vw == Vuforia::VIEW_POSTPROCESS)
        {
            continue;
        }
        
        // Set up the viewport
        Vuforia::Vec4I viewport;
        if (distortForViewer)
        {
            // We're doing distortion via an off-screen buffer, so the viewport is relative to that buffer
            viewport = renderingPrimitives.getDistortionTextureViewport(vw);
        }
        else
        {
            // We're writing directly to the screen, so the viewport is relative to the screen
            viewport = renderingPrimitives.getViewport(vw);
        }
        glViewport(viewport.data[0], viewport.data[1], viewport.data[2], viewport.data[3]);
        
        if (distortForViewer)
        {
            // We're drawing to an off-screen frame buffer, so need to clear part of that buffer
            glEnable(GL_SCISSOR_TEST);
            glScissor(viewport.data[0], viewport.data[1], viewport.data[2], viewport.data[3]);
            
            // Clear this view
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            
            glDisable(GL_SCISSOR_TEST);
        }
        
        //set scissor
        glScissor(viewport.data[0], viewport.data[1], viewport.data[2], viewport.data[3]);
        
        Vuforia::Matrix44F projectionMatrix;
        
        if (mIsVR) {
            // setup the projection matrix
            Vuforia::Matrix34F projMatrix = renderingPrimitives.getProjectionMatrix(vw, Vuforia::COORDINATE_SYSTEM_WORLD);
            
            Vuforia::Matrix44F rawProjectionMatrixGL = Vuforia::Tool::convertPerspectiveProjection2GLMatrix(
                                                                                                      projMatrix,
                                                                                                      PROJECTION_NEAR_PLANE,
                                                                                                      PROJECTION_FAR_PLANE);
            
            
            // Apply the appropriate eye adjustment to the raw projection matrix, and assign to the global variable
            Vuforia::Matrix44F eyeAdjustmentGL = Vuforia::Tool::convert2GLMatrix(renderingPrimitives.getEyeDisplayAdjustmentMatrix(vw));

            SampleApplicationUtils::multiplyMatrix(&rawProjectionMatrixGL.data[0], &eyeAdjustmentGL.data[0], &projectionMatrix.data[0]);
            
            Vuforia::Matrix44F devicePose = Vuforia::Tool::convertPose2GLMatrix(deviceViewMatrix);
            
            // transform device pose transformation to a view matrix
            Vuforia::Matrix44F deviceViewPose = MathUtils::Matrix44FTranspose(MathUtils::Matrix44FInverse(devicePose));
            
            [self renderVRWorldWithDeviceViewPose:&deviceViewPose.data[0] projectionMatrix:& projectionMatrix.data[0]];
            
        } else {
            Vuforia::Matrix34F projMatrix = renderingPrimitives.getProjectionMatrix(vw,
                                                                                 Vuforia::COORDINATE_SYSTEM_CAMERA);
            
            Vuforia::Matrix44F rawProjectionMatrixGL = Vuforia::Tool::convertPerspectiveProjection2GLMatrix(
                                                                                                      projMatrix,
                                                                                                      PROJECTION_NEAR_PLANE,
                                                                                                      PROJECTION_FAR_PLANE);
            
            // Apply the appropriate eye adjustment to the raw projection matrix, and assign to the global variable
            Vuforia::Matrix44F eyeAdjustmentGL = Vuforia::Tool::convert2GLMatrix(renderingPrimitives.getEyeDisplayAdjustmentMatrix(vw));

            SampleApplicationUtils::multiplyMatrix(&rawProjectionMatrixGL.data[0], &eyeAdjustmentGL.data[0], &projectionMatrix.data[0]);
            
            // we make a copy of the interactionViewMatrix because it will be
            // transformed in the renderARWorldWithTargetPose and we don't want
            // to do the transformations for both eyes on the same matrix
            Vuforia::Matrix44F targetPose = interactionViewMatrix;

            [self renderARWorldWithTargetPose:&targetPose.data[0] projectionMatrix:& projectionMatrix.data[0] viewId:vw viewport:viewport isARObjectVisible:isARObjectVisible];
            
        }
        glDisable(GL_SCISSOR_TEST);
        
    }
    
    // As a final step, perform the viewer distortion if required
    if (distortForViewer)
    {
        Vuforia::Vec4I screenViewport = renderingPrimitives.getViewport(Vuforia::VIEW_POSTPROCESS);
        const Vuforia::Mesh& distoMesh = renderingPrimitives.getDistortionTextureMesh(Vuforia::VIEW_POSTPROCESS);
        
        [self performViewerDistortionWithScreenViewport: screenViewport distortionMesh: distoMesh];
    }
    
    [self presentFramebuffer];
    mRenderer.end();
    
}

- (void)performViewerDistortionWithScreenViewport:(const Vuforia::Vec4I) screenViewport
                                   distortionMesh:(const Vuforia::Mesh&) distoMesh
{
    // Render the off-screen buffer to the screen using the texture
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
    
    glViewport(screenViewport.data[0], screenViewport.data[1], screenViewport.data[2], screenViewport.data[3]);
    
    glDisable(GL_SCISSOR_TEST);
    
    // Disable depth testing
    glDisable(GL_DEPTH_TEST);
    
    // setup the shaders
    glUseProgram(distoShaderProgramID);
    
    // pass our FBO texture to the shader
    glUniform1i(distoTexSampler2DHandle, 0 /* GL_TEXTURE0 */);
    
    // activate texture unit
    glActiveTexture(GL_TEXTURE0);
    
    // bind the texture with the stereo rendering
    glBindTexture(GL_TEXTURE_2D, viewerDistortionTextureID);
    
    // Enable vertex and texture coordinate vertex attribute arrays:
    glEnableVertexAttribArray(distoVertexHandle);
    glEnableVertexAttribArray(distoTexCoordHandle);
    
    // Draw geometry:
    const float* vertexCoords = distoMesh.getPositionCoordinates();
    const unsigned short* indices = distoMesh.getTriangles();
    int numIndices = distoMesh.getNumTriangles() * 3;
    const float* textureCoords = distoMesh.getUVCoordinates();
    
    glVertexAttribPointer(distoVertexHandle, 3, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)&vertexCoords[0]);
    glVertexAttribPointer(distoTexCoordHandle, 2, GL_FLOAT, GL_FALSE, 0, (const GLvoid*)&textureCoords[0]);
    glDrawElements(GL_TRIANGLES, numIndices, GL_UNSIGNED_SHORT, (const GLvoid*)&indices[0]);
    
    // Disable vertex and texture coordinate vertex attribute arrays again:
    glDisableVertexAttribArray(distoVertexHandle);
    glDisableVertexAttribArray(distoTexCoordHandle);
}

//------------------------------------------------------------------------------
#pragma mark - OpenGL ES management

- (void)initShaders
{
    shaderProgramID = [SampleApplicationShaderUtils createProgramWithVertexShaderFileName:@"Simple.vertsh"
                                                   fragmentShaderFileName:@"Simple.fragsh"];

    if (0 < shaderProgramID) {
        vertexHandle = glGetAttribLocation(shaderProgramID, "vertexPosition");
        normalHandle = glGetAttribLocation(shaderProgramID, "vertexNormal");
        textureCoordHandle = glGetAttribLocation(shaderProgramID, "vertexTexCoord");
        mvpMatrixHandle = glGetUniformLocation(shaderProgramID, "modelViewProjectionMatrix");
        texSampler2DHandle  = glGetUniformLocation(shaderProgramID,"texSampler2D");
    }
    else {
        NSLog(@"Could not initialise augmentation shader");
    }
    
    // Video background rendering
    vbShaderProgramID = [SampleApplicationShaderUtils createProgramWithVertexShaderFileName:@"Background.vertsh"
                                                                     fragmentShaderFileName:@"Background.fragsh"];
    
    if (0 < vbShaderProgramID) {
        vbVertexHandle = glGetAttribLocation(vbShaderProgramID, "vertexPosition");
        vbTexCoordHandle = glGetAttribLocation(vbShaderProgramID, "vertexTexCoord");
        vbProjectionMatrixHandle = glGetUniformLocation(vbShaderProgramID, "projectionMatrix");
        vbTexSampler2DHandle = glGetUniformLocation(vbShaderProgramID, "texSampler2D");
    }
    else {
        NSLog(@"Could not initialise video background shader");
    }
    
    // Distortion shading for when docked with a viewer
    distoShaderProgramID = [SampleApplicationShaderUtils createProgramWithVertexShaderFileName:@"DistoMesh.vertsh"
                                                                        fragmentShaderFileName:@"DistoMesh.fragsh"];
    
    if (0 < distoShaderProgramID) {
        distoVertexHandle = glGetAttribLocation(distoShaderProgramID, "vertexPosition");
        distoTexCoordHandle = glGetAttribLocation(distoShaderProgramID, "vertexTexCoord");
        distoTexSampler2DHandle = glGetUniformLocation(distoShaderProgramID, "texSampler2D");
    }
    else {
        NSLog(@"Could not initialise video background shader");
    }
    
    [self loadModels];
}

- (void)loadModels
{
    mMountainModelAR = [[Modelv3d alloc] init];
    [mMountainModelAR loadModel:@"Mountain_AR"];
    
    mMountainModelVR = [[Modelv3d alloc] init];
    [mMountainModelVR loadModel:@"Mountain_VR"];
}

- (void)unloadModels
{
    if (mMountainModelAR) {
        [mMountainModelAR unloadModel];
    }
    
    if (mMountainModelVR) {
        [mMountainModelVR unloadModel];
    }
}

- (void)createFramebuffer
{
    if (context) {
        // Create default framebuffer object
        glGenFramebuffers(1, &defaultFramebuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
        
        // Create colour renderbuffer and allocate backing store
        glGenRenderbuffers(1, &colorRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
        
        // Allocate the renderbuffer's storage (shared with the drawable object)
        [context renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer*)self.layer];
        GLint framebufferWidth;
        GLint framebufferHeight;
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &framebufferWidth);
        glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &framebufferHeight);
        
        // Create the depth render buffer and allocate storage
        glGenRenderbuffers(1, &depthRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, depthRenderbuffer);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, framebufferWidth, framebufferHeight);
        
        // Attach colour and depth render buffers to the frame buffer
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, colorRenderbuffer);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depthRenderbuffer);
        
        // Leave the colour render buffer bound so future rendering operations will act on it
        glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    }
}


- (void)deleteFramebuffer
{
    if (context) {
        [EAGLContext setCurrentContext:context];
        
        if (defaultFramebuffer) {
            glDeleteFramebuffers(1, &defaultFramebuffer);
            defaultFramebuffer = 0;
        }
        
        if (colorRenderbuffer) {
            glDeleteRenderbuffers(1, &colorRenderbuffer);
            colorRenderbuffer = 0;
        }
        
        if (depthRenderbuffer) {
            glDeleteRenderbuffers(1, &depthRenderbuffer);
            depthRenderbuffer = 0;
        }
    }
}


- (void)setFramebuffer
{
    // The EAGLContext must be set for each thread that wishes to use it.  Set
    // it the first time this method is called (on the render thread)
    if (context != [EAGLContext currentContext]) {
        [EAGLContext setCurrentContext:context];
    }
    
    if (!defaultFramebuffer) {
        // Perform on the main thread to ensure safe memory allocation for the
        // shared buffer.  Block until the operation is complete to prevent
        // simultaneous access to the OpenGL context
        [self performSelectorOnMainThread:@selector(createFramebuffer) withObject:self waitUntilDone:YES];
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, defaultFramebuffer);
}


- (BOOL)presentFramebuffer
{
    // setFramebuffer must have been called before presentFramebuffer, therefore
    // we know the context is valid and has been set for this (render) thread
    
    // Bind the colour render buffer and present it
    glBindRenderbuffer(GL_RENDERBUFFER, colorRenderbuffer);
    
    return [context presentRenderbuffer:GL_RENDERBUFFER];
}

- (BOOL) prepareViewerDistortionWithTextureSize:(const Vuforia::Vec2I) textureSize
{
    // Check if the texture size is valid; if not, the configuration doesn't support distortion
    if (textureSize.data[0] == 0 || textureSize.data[1] == 0)
    {
        // Log a warning
        NSLog(@"Viewer distortion is not supported in this configuration");
        
        // Tidy up and return without setting anything up
        _viewerDistortionTextureSize = textureSize;
        
        return NO;
    }
    
    // If the texture has changed size, then regenerate the off-screen frame buffer
    // (the default texture is (0,0), so this will happen on the first frame)
    if ((textureSize.data[0] != _viewerDistortionTextureSize.data[0]) ||
        (textureSize.data[1] != _viewerDistortionTextureSize.data[1]))
    {
        if (viewerDistortionFboID == 0) {
            // Create frame buffer for when performing barrel distortion docked in a viewer
            glGenFramebuffers(1, &viewerDistortionFboID);
        }
        
        // bind the texture
        glBindTexture(GL_TEXTURE_2D, viewerDistortionTextureID);
        SampleApplicationUtils::checkGlError("Failed to bind texture for viewer distortion");
        
        
        // initialize texture size, format, pixel size
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB,
                     textureSize.data[0], textureSize.data[1],
                     0, GL_RGB, GL_UNSIGNED_BYTE, 0);
        
        // configure texture parameters
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        SampleApplicationUtils::checkGlError("Failed to set texture for viewer distortion");
        
        
        // remember this texture size for next time round
        _viewerDistortionTextureSize = textureSize;
        
        // route all drawing commands to the off-screen frame buffer
        glBindFramebuffer(GL_FRAMEBUFFER, viewerDistortionFboID);
        SampleApplicationUtils::checkGlError("Failed to bind frame buffer for viewer distortion");
        
        // Create the depth render buffer and allocate storage
        glGenTextures(1, &viewerDepthTextureID);
        glBindTexture(GL_TEXTURE_2D, viewerDepthTextureID);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT,
                     textureSize.data[0], textureSize.data[1],
                     0, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, 0);
        
        // Attach the distortion (with depth buffer)texture to the off-screen frame buffer
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, viewerDistortionTextureID, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, viewerDepthTextureID, 0);
    }
    else
    {
        // route all drawing commands to the off-screen frame buffer
        glBindFramebuffer(GL_FRAMEBUFFER, viewerDistortionFboID);
    }
    
    SampleApplicationUtils::checkGlError("Failed to prepare for viewer distortion");
    
    return YES;
}

- (void) renderVideoBackgroundWithViewId:(Vuforia::VIEW) viewId textureUnit:(int) vbVideoTextureUnit viewPort:(Vuforia::Vec4I) viewport
{
    const Vuforia::RenderingPrimitives renderingPrimitives = Vuforia::Device::getInstance().getRenderingPrimitives();

    Vuforia::Matrix44F vbProjectionMatrix = Vuforia::Tool::convert2GLMatrix(
                  renderingPrimitives.getVideoBackgroundProjectionMatrix(viewId, Vuforia::COORDINATE_SYSTEM_CAMERA));
    
    // Apply the scene scale on video see-through eyewear, to scale the video background and augmentation
    // so that the display lines up with the real world
    // This should not be applied on optical see-through devices, as there is no video background,
    // and the calibration ensures that the augmentation matches the real world
    if (Vuforia::Device::getInstance().isViewerActive())
    {
        float sceneScaleFactor = [self getSceneScaleFactor];
        SampleApplicationUtils::scalePoseMatrix(sceneScaleFactor, sceneScaleFactor, 1.0f, vbProjectionMatrix.data);
        
        // Apply a scissor around the video background, so that the augmentation doesn't 'bleed' outside it
        int videoWidth = viewport.data[2] * sceneScaleFactor * 2;
        int videoHeight = viewport.data[3] * sceneScaleFactor;
        int videoX = (viewport.data[2] - videoWidth) / 2 + viewport.data[0];
        int videoY = (viewport.data[3] - videoHeight) / 2 + viewport.data[1];
        
        glEnable(GL_SCISSOR_TEST);
        glScissor(videoX, videoY, videoWidth, videoHeight);
    }
    
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);
    
    const Vuforia::Mesh& vbMesh = renderingPrimitives.getVideoBackgroundMesh(viewId);
    // Load the shader and upload the vertex/texcoord/index data
    glUseProgram(vbShaderProgramID);
    glVertexAttribPointer(vbVertexHandle, 3, GL_FLOAT, false, 0, vbMesh.getPositionCoordinates());
    glVertexAttribPointer(vbTexCoordHandle, 2, GL_FLOAT, false, 0, vbMesh.getUVCoordinates());
    
    glUniform1i(vbTexSampler2DHandle, vbVideoTextureUnit);
    
    // Render the video background with the custom shader
    // First, we enable the vertex arrays
    glEnableVertexAttribArray(vbVertexHandle);
    glEnableVertexAttribArray(vbTexCoordHandle);
    
    // Pass the projection matrix to OpenGL
    glUniformMatrix4fv(vbProjectionMatrixHandle, 1, GL_FALSE, vbProjectionMatrix.data);
    
    // Then, we issue the render call
    glDrawElements(GL_TRIANGLES, vbMesh.getNumTriangles() * 3, GL_UNSIGNED_SHORT,
                   vbMesh.getTriangles());
    
    // Finally, we disable the vertex arrays
    glDisableVertexAttribArray(vbVertexHandle);
    glDisableVertexAttribArray(vbTexCoordHandle);
    
    SampleApplicationUtils::checkGlError("Rendering of the video background failed");
}


-(float) getSceneScaleFactor
{
    static const float VIRTUAL_FOV_Y_DEGS = 85.0f;
    
    // Get the y-dimension of the physical camera field of view
    Vuforia::Vec2F fovVector = Vuforia::CameraDevice::getInstance().getCameraCalibration().getFieldOfViewRads();
    float cameraFovYRads = fovVector.data[1];
    
    // Get the y-dimension of the virtual camera field of view
    float virtualFovYRads = VIRTUAL_FOV_Y_DEGS * M_PI / 180;
    
    // The scene-scale factor represents the proportion of the viewport that is filled by
    // the video background when projected onto the same plane.
    // In order to calculate this, let 'd' be the distance between the cameras and the plane.
    // The height of the projected image 'h' on this plane can then be calculated:
    //   tan(fov/2) = h/2d
    // which rearranges to:
    //   2d = h/tan(fov/2)
    // Since 'd' is the same for both cameras, we can combine the equations for the two cameras:
    //   hPhysical/tan(fovPhysical/2) = hVirtual/tan(fovVirtual/2)
    // Which rearranges to:
    //   hPhysical/hVirtual = tan(fovPhysical/2)/tan(fovVirtual/2)
    // ... which is the scene-scale factor
    return tan(cameraFovYRads / 2) / tan(virtualFovYRads / 2);
}

- (void) renderVRWorldWithDeviceViewPose:(float *) deviceViewPose projectionMatrix:(float *)projectionMatrix {
    Vuforia::Matrix44F modelViewMatrix;
    Vuforia::Matrix44F worldInitialPositionMatrix = MathUtils::Matrix44FIdentity();
    Vuforia::Matrix44F mvpMatrix;
    
    glClear(GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    
    SampleApplicationUtils::translatePoseMatrix(0.0, -1.7, 0.0f,
                             &worldInitialPositionMatrix.data[0]);// Translate 1.7 meters since it is the average human height
    SampleApplicationUtils::rotatePoseMatrix(-90, 1, 0, 0, &worldInitialPositionMatrix.data[0]);
    
    SampleApplicationUtils::scalePoseMatrix(0.5f, 0.5f, 0.5f, &worldInitialPositionMatrix.data[0]);

    SampleApplicationUtils::multiplyMatrix(deviceViewPose, &worldInitialPositionMatrix.data[0], &modelViewMatrix.data[0]);

    SampleApplicationUtils::multiplyMatrix(projectionMatrix, &modelViewMatrix.data[0], &mvpMatrix.data[0]);
    
    [mMountainModelVR renderWithModelView:&modelViewMatrix.data[0] modelViewProjMatrix:&mvpMatrix.data[0]];
}

- (void) renderARWorldWithTargetPose:(float *) targetPose projectionMatrix:(float *) projection viewId:(Vuforia::VIEW) viewId viewport:(Vuforia::Vec4I)viewport
                   isARObjectVisible:(bool) arObjectVisible {
    // Use texture unit 0 for the video background - this will hold the camera frame and we want to reuse for all views
    // So need to use a different texture unit for the augmentation
    int vbVideoTextureUnit = 0;
    
    // Bind the video bg texture and get the Texture ID from Vuforia
    Vuforia::GLTextureUnit tex;
    tex.mTextureUnit = vbVideoTextureUnit;
    
    if (viewId != Vuforia::VIEW_RIGHTEYE )
    {
        if (! Vuforia::Renderer::getInstance().updateVideoBackgroundTexture(&tex))
        {
            NSLog(@"Unable to bind video background texture!!");
            return;
        }
    }
    [self renderVideoBackgroundWithViewId:viewId textureUnit:vbVideoTextureUnit viewPort:viewport];
    
    glClear(GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glCullFace(GL_BACK);
    
    // Check if the viewer is active and set a scissor test to clip the augmentation to be constrained inside of the video background
    if(Vuforia::Device::getInstance().isViewerActive()) {
        float sceneScaleFactor = [self getSceneScaleFactor];
        SampleApplicationUtils::scalePoseMatrix(sceneScaleFactor, sceneScaleFactor, 1.0, projection);
        
        // Apply a scissor around the video background, so that the augmentation doesn't 'bleed' outside it
        // Add one due to rounding to integer
        int videoWidth = (int)(viewport.data[2] * sceneScaleFactor * 2 + 1);
        int videoHeight = (int)(viewport.data[3] * sceneScaleFactor + 1);
        int videoX = (viewport.data[2] - videoWidth) / 2 + viewport.data[0];
        int videoY = (viewport.data[3] - videoHeight) / 2 + viewport.data[1];
        
        glEnable(GL_SCISSOR_TEST);
        glScissor(videoX, videoY, videoWidth, videoHeight);
    }
    
    // If target detected render the augmentation
    if (arObjectVisible)
    {
        if(Vuforia::Renderer::getInstance().getVideoBackgroundConfig().mReflection == Vuforia::VIDEO_BACKGROUND_REFLECTION_ON)
            glFrontFace(GL_CW);  //Front camera
        else
            glFrontFace(GL_CCW);   //Back camera
        
        Vuforia::Matrix44F modelViewProjection;
        
        // deal with the modelview and projection matrices
        SampleApplicationUtils::rotatePoseMatrix(90, 1, 0, 0, targetPose);
        SampleApplicationUtils::translatePoseMatrix(0.0, 0.0, AR_OBJECT_SCALE_FLOAT,
                                                    targetPose);
        
        SampleApplicationUtils::scalePoseMatrix(AR_OBJECT_SCALE_FLOAT, AR_OBJECT_SCALE_FLOAT, AR_OBJECT_SCALE_FLOAT, targetPose);
        
        SampleApplicationUtils::multiplyMatrix(projection, targetPose, &modelViewProjection.data[0]);
        
        [mMountainModelAR renderWithModelView:targetPose modelViewProjMatrix:&modelViewProjection.data[0]];
        
    }
    
    if(Vuforia::Device::getInstance().isViewerActive())
    {
        glDisable(GL_SCISSOR_TEST);
    }
}



@end
