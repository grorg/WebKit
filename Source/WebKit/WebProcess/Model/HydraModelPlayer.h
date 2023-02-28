/*
 * Copyright (C) 2021 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#pragma once

#if ENABLE(ARKIT_INLINE_PREVIEW)

#import "ModelIdentifier.h"
#import "WebPage.h"
#import "WebPageProxyMessages.h"
#import <WebCore/ModelPlayer.h>
#import <WebCore/ModelPlayerClient.h>
#import <wtf/Compiler.h>

namespace WebKit {

class HydraModelPlayer : public WebCore::ModelPlayer, public CanMakeWeakPtr<HydraModelPlayer> {
public:
    static Ref<HydraModelPlayer> create(WebPage&, WebCore::ModelPlayerClient&);
    virtual ~HydraModelPlayer();

    static void setModelElementCacheDirectory(const String&);
    static const String& modelElementCacheDirectory();

protected:
    explicit HydraModelPlayer(WebPage&, WebCore::ModelPlayerClient&);

    WebPage* page() { return m_page.get(); }
    WebCore::ModelPlayerClient* client() { return m_client.get(); }

private:
    std::optional<ModelIdentifier> modelIdentifier();

    // WebCore::ModelPlayer overrides.
    void load(WebCore::Model&, WebCore::LayoutSize) override;
    void sizeDidChange(WebCore::LayoutSize) override;
    PlatformLayer* layer() override;
    void enterFullscreen() override;
    WebCore::HTMLModelElementCamera getCamera() override;
    void setCamera(WebCore::HTMLModelElementCamera) override;
    void isPlayingAnimation(CompletionHandler<void(std::optional<bool>&&)>&&) override;
    void setAnimationIsPlaying(bool, CompletionHandler<void(bool success)>&&) override;
    void isLoopingAnimation(CompletionHandler<void(std::optional<bool>&&)>&&) override;
    void setIsLoopingAnimation(bool, CompletionHandler<void(bool success)>&&) override;
    void animationDuration(CompletionHandler<void(std::optional<Seconds>&&)>&&) override;
    void animationCurrentTime(CompletionHandler<void(std::optional<Seconds>&&)>&&) override;
    void setAnimationCurrentTime(Seconds, CompletionHandler<void(bool success)>&&) override;

    void handleMouseDown(const WebCore::LayoutPoint&, MonotonicTime) override;
    void handleMouseMove(const WebCore::LayoutPoint&, MonotonicTime) override;
    void handleMouseUp(const WebCore::LayoutPoint&, MonotonicTime) override;

    bool hasAudio() override;
    bool isMuted() override;
    void setIsMuted(bool) override;
    Vector<RetainPtr<id>> accessibilityChildren() override;

    void createFile(WebCore::Model&);
    void clearFile();

    void createOutputForModelWithURL(const URL&);
    void didCreateOutputForModelWithURL(const URL&);

    WeakPtr<WebPage> m_page;
    WeakPtr<WebCore::ModelPlayerClient> m_client;
    WebCore::LayoutSize m_size;
    String m_uuid;
    String m_filePath;
    bool m_remoteRendererCreated;
};

}

#endif
