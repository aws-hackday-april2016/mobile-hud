/*===============================================================================
Copyright (c) 2016 PTC Inc. All Rights Reserved.

Copyright (c) 2012-2015 Qualcomm Connected Experiences, Inc. All Rights Reserved.

Vuforia is a trademark of PTC Inc., registered in the United States and other 
countries.
===============================================================================*/

#import <UIKit/UIKit.h>

#import <Vuforia/UIGLViewProtocol.h>

#import "Texture.h"
#import "SampleApplicationSession.h"
#import "SampleGLResourceHandler.h"

static const int kNumAugmentationTextures = 4;

namespace {
    // --- Data private to this unit ---
    
    const float AR_OBJECT_SCALE_FLOAT = 0.025f;
    const float skyColor[] = {0.4f, 0.5f, 0.6f, 1.0f};
}

// FrameMarkers is a subclass of UIView and conforms to the informal protocol
// UIGLViewProtocol
@interface FrameMarkersEAGLView : UIView <UIGLViewProtocol, SampleGLResourceHandler> {
@private
    // OpenGL ES context
    EAGLContext *context;
    bool isARObjectVisible;
    
    Vuforia::Matrix44F interactionViewMatrix;
    Vuforia::Matrix34F deviceViewMatrix;
    
    // The OpenGL ES names for the framebuffer and renderbuffers used to render
    // to this view
    GLuint defaultFramebuffer;
    GLuint colorRenderbuffer;
    GLuint depthRenderbuffer;

    // Shader handles
    GLuint shaderProgramID;
    GLint vertexHandle;
    GLint normalHandle;
    GLint textureCoordHandle;
    GLint mvpMatrixHandle;
    GLint texSampler2DHandle;
    
    GLuint vbShaderProgramID;
    GLint vbVertexHandle;
    GLint vbTexCoordHandle;
    GLint vbTexSampler2DHandle;
    GLint vbProjectionMatrixHandle;
    
    // Texture used when rendering augmentation
    Texture* augmentationTexture[kNumAugmentationTextures];
    NSMutableArray *objects3D;  // objects to draw
    
    unsigned int distoShaderProgramID;
    GLint distoVertexHandle;
    GLint distoTexCoordHandle;
    GLint distoTexSampler2DHandle;
    
    GLuint viewerDistortionTextureID;
    GLuint viewerDepthTextureID;
    GLuint viewerDistortionFboID;

    BOOL offTargetTrackingEnabled;
}

@property (nonatomic, weak) SampleApplicationSession * vapp;

- (id)initWithFrame:(CGRect)frame appSession:(SampleApplicationSession *) app;

- (void)finishOpenGLESCommands;
- (void)freeOpenGLESResources;

@end

