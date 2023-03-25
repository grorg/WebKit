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

#import "config.h"
#import "HydraModelPlayer.h"

#if ENABLE(HYDRA_MODEL)

#import "DrawingArea.h"
#import "Logging.h"
#import "WebPage.h"
#import "WebPageProxyMessages.h"
#import <WebCore/Model.h>
#import <pal/spi/cocoa/QuartzCoreSPI.h>
#import <pal/spi/mac/SystemPreviewSPI.h>
#import <wtf/MachSendRight.h>
#import <wtf/SoftLinking.h>
#import <wtf/UUID.h>

#import <Hydra/Hydra.h>

namespace WebKit {

Ref<HydraModelPlayer> HydraModelPlayer::create(WebPage& page, WebCore::ModelPlayerClient& client)
{
    return adoptRef(*new HydraModelPlayer(page, client));
}

HydraModelPlayer::HydraModelPlayer(WebPage& page, WebCore::ModelPlayerClient& client)
    : m_page { page }
    , m_client { client }
    , m_remoteRendererCreated { false }
{
}

HydraModelPlayer::~HydraModelPlayer()
{
    if (m_remoteRendererCreated) {
        if (auto* page = this->page())
            page->send(Messages::WebPageProxy::HydraModelElementDestroyRemotePreview(m_uuid));
    }
    clearFile();
}

std::optional<ModelIdentifier> HydraModelPlayer::modelIdentifier()
{
    return { { m_uuid } };
}

static String& hydraSharedModelElementCacheDirectory()
{
    static NeverDestroyed<String> sharedModelElementCacheDirectory;
    return sharedModelElementCacheDirectory;
}

const String& HydraModelPlayer::modelElementCacheDirectory()
{
    return hydraSharedModelElementCacheDirectory();
}

void HydraModelPlayer::setModelElementCacheDirectory(const String& path)
{
    hydraSharedModelElementCacheDirectory() = path;
}

void HydraModelPlayer::createFile(WebCore::Model& modelSource)
{
    // The need for a file is only temporary due to the nature of ASVInlinePreview,
    // https://bugs.webkit.org/show_bug.cgi?id=227567.

    clearFile();

    auto pathToDirectory = modelElementCacheDirectory();
    if (pathToDirectory.isEmpty())
        return;

    auto directoryExists = FileSystem::fileExists(pathToDirectory);
    if (directoryExists && FileSystem::fileTypeFollowingSymlinks(pathToDirectory) != FileSystem::FileType::Directory) {
        ASSERT_NOT_REACHED();
        return;
    }
    if (!directoryExists && !FileSystem::makeAllDirectories(pathToDirectory)) {
        ASSERT_NOT_REACHED();
        return;
    }

    // We need to support .reality files as well, https://bugs.webkit.org/show_bug.cgi?id=227568.
    String fileName = makeString(UUID::createVersion4(), ".usdz"_s);
    auto filePath = FileSystem::pathByAppendingComponent(pathToDirectory, fileName);
    auto file = FileSystem::openFile(filePath, FileSystem::FileOpenMode::Truncate);
    if (file <= 0)
        return;

    FileSystem::writeToFile(file, modelSource.data()->makeContiguous()->data(), modelSource.data()->size());
    FileSystem::closeFile(file);
    m_filePath = filePath;
}

void HydraModelPlayer::clearFile()
{
    if (m_filePath.isEmpty())
        return;

    FileSystem::deleteFile(m_filePath);
    m_filePath = emptyString();
}

// MARK: - WebCore::ModelPlayer overrides.

void HydraModelPlayer::load(WebCore::Model& modelSource, WebCore::LayoutSize size)
{
    m_size = size;

    auto strongClient = client();
    if (!strongClient)
        return;

    RefPtr strongPage = page();
    if (!strongPage) {
        strongClient->didFailLoading(*this, WebCore::ResourceError { WebCore::errorDomainWebKitInternal, 0, modelSource.url(), "WebPage destroyed"_s });
        return;
    }

    createFile(modelSource);
    createOutputForModelWithURL(modelSource.url());
}

void HydraModelPlayer::createOutputForModelWithURL(const URL& url)
{
    // First, create the WebProcess proxy.
    m_uuid = createVersion4UUIDString();
    LOG(ModelElement, "HydraModelPlayer::createOutputForModelWithURL() created preview with UUID %s and size %f x %f.", m_uuid.utf8().data(), m_size.width(), m_size.height());

    auto strongClient = client();
    if (!strongClient)
        return;

    RefPtr strongPage = page();
    if (!strongPage) {
        strongClient->didFailLoading(*this, WebCore::ResourceError { WebCore::errorDomainWebKitInternal, 0, url, "WebPage destroyed"_s });
        return;
    }

    CompletionHandler<void(Expected<String, WebCore::ResourceError>)> completionHandler = [weakSelf = WeakPtr { *this }, url] (Expected<String, WebCore::ResourceError> result) mutable {
        RefPtr strongSelf = weakSelf.get();
        if (!strongSelf)
            return;

        auto strongClient = strongSelf->client();
        if (!strongClient)
            return;

        if (!result) {
            LOG(ModelElement, "HydraModelPlayer::createOutputForModelWithURL() received error from UIProcess");
            strongClient->didFailLoading(*strongSelf, result.error());
            return;
        }

        auto& uuid = *result;
        String expectedUUID = strongSelf->m_uuid;

        if (uuid != expectedUUID) {
            LOG(ModelElement, "HydraModelPlayer::createOutputForModelWithURL() UUID mismatch, received %s but expected %s.", uuid.utf8().data(), expectedUUID.utf8().data());
            strongClient->didFailLoading(*strongSelf, WebCore::ResourceError { WebCore::errorDomainWebKitInternal, 0, { }, makeString("HydraModelPlayer::createPreviewsForModelWithURL() UUID mismatch, received ", uuid, " but expected ", expectedUUID, ".") });
            return;
        }

        LOG(ModelElement, "HydraModelPlayer::createOutputForModelWithURL() successfully established remote connection for UUID %s.", uuid.utf8().data());

        strongSelf->m_remoteRendererCreated = true;

        strongSelf->didCreateOutputForModelWithURL(url);
    };

    // Then, create the UIProcess preview.
    strongPage->sendWithAsyncReply(Messages::WebPageProxy::HydraModelElementCreateRemotePreview(m_uuid, m_size), WTFMove(completionHandler));
}

void HydraModelPlayer::didCreateOutputForModelWithURL(const URL& url)
{
    auto strongClient = client();
    if (!strongClient)
        return;

    RefPtr strongPage = page();
    if (!strongPage) {
        strongClient->didFailLoading(*this, WebCore::ResourceError { WebCore::errorDomainWebKitInternal, 0, url, "WebPage destroyed"_s });
        return;
    }

    CompletionHandler<void(std::optional<WebCore::ResourceError>&&)> completionHandler = [weakSelf = WeakPtr { *this }] (std::optional<WebCore::ResourceError>&& error) mutable {
        RefPtr strongSelf = weakSelf.get();
        if (!strongSelf)
            return;

        auto strongClient = strongSelf->client();
        if (!strongClient)
            return;

        if (error) {
            LOG(ModelElement, "HydraModelPlayer::didCreateRemotePreviewForModelWithURL() received error from UIProcess");
            strongClient->didFailLoading(*strongSelf, *error);
            return;
        }

        LOG(ModelElement, "HydraModelPlayer::didCreateRemotePreviewForModelWithURL() successfully completed load for UUID %s.", strongSelf->m_uuid.utf8().data());

        strongClient->didFinishLoading(*strongSelf);
    };

    // Now that both the WebProcess and UIProcess previews are created, load the file into the remote preview.
    strongPage->sendWithAsyncReply(Messages::WebPageProxy::HydraModelElementLoadRemotePreview(m_uuid, URL::fileURLWithFileSystemPath(m_filePath)), WTFMove(completionHandler));
}


void HydraModelPlayer::sizeDidChange(WebCore::LayoutSize size)
{
    if (m_size == size)
        return;

    m_size = size;

    RefPtr strongPage = page();
    if (!strongPage)
        return;

    CompletionHandler<void(Expected<MachSendRight, WebCore::ResourceError>)> completionHandler = [weakSelf = WeakPtr { *this }, strongPage, size] (Expected<MachSendRight, WebCore::ResourceError> result) mutable {
        if (!result)
            return;

        RefPtr strongSelf = weakSelf.get();
        if (!strongSelf)
            return;

        auto* drawingArea = strongPage->drawingArea();
        if (!drawingArea)
            return;

        auto fenceSendRight = *result;
        drawingArea->addFence(fenceSendRight);

        UNUSED_PARAM(size);
        WTFLogAlways("dino> ***** FIXME **** update local size");
//        [strongSelf->m_hydra setFrameWithinFencedTransaction:CGRectMake(0, 0, size.width(), size.height())];
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::HydraModelElementSizeDidChange(m_uuid, size), WTFMove(completionHandler));
}

PlatformLayer* HydraModelPlayer::layer()
{
    return nil;
}

void HydraModelPlayer::handleMouseDown(const LayoutPoint& flippedLocationInElement, MonotonicTime timestamp)
{
    if (auto* page = this->page())
        page->send(Messages::WebPageProxy::HydraHandleMouseDownForModelElement(m_uuid, flippedLocationInElement, timestamp));
}

void HydraModelPlayer::handleMouseMove(const LayoutPoint& flippedLocationInElement, MonotonicTime timestamp)
{
    if (auto* page = this->page())
        page->send(Messages::WebPageProxy::HydraHandleMouseMoveForModelElement(m_uuid, flippedLocationInElement, timestamp));
}

void HydraModelPlayer::handleMouseUp(const LayoutPoint& flippedLocationInElement, MonotonicTime timestamp)
{
    if (auto* page = this->page())
        page->send(Messages::WebPageProxy::HydraHandleMouseUpForModelElement(m_uuid, flippedLocationInElement, timestamp));
}

void HydraModelPlayer::enterFullscreen()
{
}

WebCore::HTMLModelElementCamera HydraModelPlayer::getCamera()
{
    return WebCore::HTMLModelElementCamera { };
//    auto modelIdentifier = this->modelIdentifier();
//    if (!modelIdentifier) {
//        completionHandler(std::nullopt);
//        return;
//    }
//
//    RefPtr strongPage = m_page.get();
//    if (!strongPage) {
//        completionHandler(std::nullopt);
//        return;
//    }
//
//    CompletionHandler<void(Expected<WebCore::HTMLModelElementCamera, WebCore::ResourceError>)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (Expected<WebCore::HTMLModelElementCamera, WebCore::ResourceError> result) mutable {
//        if (!result) {
//            completionHandler(std::nullopt);
//            return;
//        }
//
//        completionHandler(*result);
//    };
//
//    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementGetCamera(*modelIdentifier), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::setCamera(WebCore::HTMLModelElementCamera camera)
{
    UNUSED_PARAM(camera);
//    auto modelIdentifier = this->modelIdentifier();
//    if (!modelIdentifier) {
//        completionHandler(false);
//        return;
//    }
//
//    RefPtr strongPage = m_page.get();
//    if (!strongPage) {
//        completionHandler(false);
//        return;
//    }
//
//    CompletionHandler<void(bool)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (bool success) mutable {
//        completionHandler(success);
//    };
//
//    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementSetCamera(*modelIdentifier, camera), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::isPlayingAnimation(CompletionHandler<void(std::optional<bool>&&)>&& completionHandler)
{
    auto modelIdentifier = this->modelIdentifier();
    if (!modelIdentifier) {
        completionHandler(std::nullopt);
        return;
    }

    RefPtr strongPage = m_page.get();
    if (!strongPage) {
        completionHandler(std::nullopt);
        return;
    }

    CompletionHandler<void(Expected<bool, WebCore::ResourceError>)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (Expected<bool, WebCore::ResourceError> result) mutable {
        if (!result) {
            completionHandler(std::nullopt);
            return;
        }

        completionHandler(*result);
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementIsPlayingAnimation(*modelIdentifier), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::setAnimationIsPlaying(bool isPlaying, CompletionHandler<void(bool success)>&& completionHandler)
{
    auto modelIdentifier = this->modelIdentifier();
    if (!modelIdentifier) {
        completionHandler(false);
        return;
    }

    RefPtr strongPage = m_page.get();
    if (!strongPage) {
        completionHandler(false);
        return;
    }

    CompletionHandler<void(bool)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (bool success) mutable {
        completionHandler(success);
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementSetAnimationIsPlaying(*modelIdentifier, isPlaying), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::isLoopingAnimation(CompletionHandler<void(std::optional<bool>&&)>&& completionHandler)
{
    auto modelIdentifier = this->modelIdentifier();
    if (!modelIdentifier) {
        completionHandler(std::nullopt);
        return;
    }

    RefPtr strongPage = m_page.get();
    if (!strongPage) {
        completionHandler(std::nullopt);
        return;
    }

    CompletionHandler<void(Expected<bool, WebCore::ResourceError>)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (Expected<bool, WebCore::ResourceError> result) mutable {
        if (!result) {
            completionHandler(std::nullopt);
            return;
        }

        completionHandler(*result);
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementIsLoopingAnimation(*modelIdentifier), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::setIsLoopingAnimation(bool isLooping, CompletionHandler<void(bool success)>&& completionHandler)
{
    auto modelIdentifier = this->modelIdentifier();
    if (!modelIdentifier) {
        completionHandler(false);
        return;
    }

    RefPtr strongPage = m_page.get();
    if (!strongPage) {
        completionHandler(false);
        return;
    }

    CompletionHandler<void(bool)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (bool success) mutable {
        completionHandler(success);
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementSetIsLoopingAnimation(*modelIdentifier, isLooping), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::animationDuration(CompletionHandler<void(std::optional<Seconds>&&)>&& completionHandler)
{
    auto modelIdentifier = this->modelIdentifier();
    if (!modelIdentifier) {
        completionHandler(std::nullopt);
        return;
    }

    RefPtr strongPage = m_page.get();
    if (!strongPage) {
        completionHandler(std::nullopt);
        return;
    }

    CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (Expected<Seconds, WebCore::ResourceError> result) mutable {
        if (!result) {
            completionHandler(std::nullopt);
            return;
        }

        completionHandler(*result);
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementAnimationDuration(*modelIdentifier), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::animationCurrentTime(CompletionHandler<void(std::optional<Seconds>&&)>&& completionHandler)
{
    auto modelIdentifier = this->modelIdentifier();
    if (!modelIdentifier) {
        completionHandler(std::nullopt);
        return;
    }

    RefPtr strongPage = m_page.get();
    if (!strongPage) {
        completionHandler(std::nullopt);
        return;
    }

    CompletionHandler<void(Expected<Seconds, WebCore::ResourceError>)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (Expected<Seconds, WebCore::ResourceError> result) mutable {
        if (!result) {
            completionHandler(std::nullopt);
            return;
        }

        completionHandler(*result);
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementAnimationCurrentTime(*modelIdentifier), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::setAnimationCurrentTime(Seconds currentTime, CompletionHandler<void(bool success)>&& completionHandler)
{
    auto modelIdentifier = this->modelIdentifier();
    if (!modelIdentifier) {
        completionHandler(false);
        return;
    }

    RefPtr strongPage = m_page.get();
    if (!strongPage) {
        completionHandler(false);
        return;
    }

    CompletionHandler<void(bool)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (bool success) mutable {
        completionHandler(success);
    };

    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementSetAnimationCurrentTime(*modelIdentifier, currentTime), WTFMove(remoteCompletionHandler));
}

bool HydraModelPlayer::hasAudio()
{
    return false;
//    auto modelIdentifier = this->modelIdentifier();
//    if (!modelIdentifier) {
//        completionHandler(std::nullopt);
//        return;
//    }
//
//    RefPtr strongPage = m_page.get();
//    if (!strongPage) {
//        completionHandler(std::nullopt);
//        return;
//    }
//
//    CompletionHandler<void(Expected<bool, WebCore::ResourceError>)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (Expected<bool, WebCore::ResourceError> result) mutable {
//        if (!result) {
//            completionHandler(std::nullopt);
//            return;
//        }
//
//        completionHandler(*result);
//    };
//
//    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementHasAudio(*modelIdentifier), WTFMove(remoteCompletionHandler));
}

bool HydraModelPlayer::isMuted()
{
    return false;
//    auto modelIdentifier = this->modelIdentifier();
//    if (!modelIdentifier) {
//        completionHandler(std::nullopt);
//        return;
//    }
//
//    RefPtr strongPage = m_page.get();
//    if (!strongPage) {
//        completionHandler(std::nullopt);
//        return;
//    }
//
//    CompletionHandler<void(Expected<bool, WebCore::ResourceError>)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (Expected<bool, WebCore::ResourceError> result) mutable {
//        if (!result) {
//            completionHandler(std::nullopt);
//            return;
//        }
//
//        completionHandler(*result);
//    };
//
//    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementIsMuted(*modelIdentifier), WTFMove(remoteCompletionHandler));
}

void HydraModelPlayer::setIsMuted(bool isMuted)
{
    UNUSED_PARAM(isMuted);
//    auto modelIdentifier = this->modelIdentifier();
//    if (!modelIdentifier) {
//        completionHandler(false);
//        return;
//    }
//
//    RefPtr strongPage = m_page.get();
//    if (!strongPage) {
//        completionHandler(false);
//        return;
//    }
//
//    CompletionHandler<void(bool)> remoteCompletionHandler = [completionHandler = WTFMove(completionHandler)] (bool success) mutable {
//        completionHandler(success);
//    };
//
//    strongPage->sendWithAsyncReply(Messages::WebPageProxy::ModelElementSetIsMuted(*modelIdentifier, isMuted), WTFMove(remoteCompletionHandler));
}

Vector<RetainPtr<id>> HydraModelPlayer::accessibilityChildren()
{
    // FIXME: https://webkit.org/b/233575 Need to return something to create a remote element connection to the InlinePreviewModel hosted in another process.
    return { };
}

}

#endif
