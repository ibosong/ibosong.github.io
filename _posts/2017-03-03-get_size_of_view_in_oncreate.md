---
title: onCreate中获取View的宽高为0？
date: 2017-03-03 15:03:00
categories:
  - Android
tags:
  - android
  - java
---

开发的过程中，我们有时候需要在`Activity`启动以后第一时间获取某个View的宽高，并作相应处理，当我们在`onCreate`中通过`View.getWidth`（或`getMeasuredWidth`）和`View.getHeight`（或`getMeasuredHeight`）方法获取的时候，你会发现它们都返回0。我们猜测是因为，这个时候View还没有布局完成。解决的办法有很多种，比如在`View`的`OnGlobalLayoutListener`中获取，在`onLayout`中获取等等，具体请参考StackOverflow：
<https://stackoverflow.com/questions/18861585/get-content-view-size-in-oncreate>

有另外一个方法，有些人应该也知道，在`onCreate`中通过`View.post`，在其中的`Runnable`中就能获取到正确的宽高。那么，这里的原理是什么，很多人认为这里就是一个时间差，等`View`的`measure`和`layout`完了就有宽和高了，有些人甚至使用`postDelay`延迟几秒来确保万无一失。那么这里面到底会不会有不稳定的因素呢？这篇文章告诉你答案。

本篇文章分析的是Android6.0系统的源码。阅读之前，请先了解Android中`Handler`，`Looper`和`MessageQueue`等概念，推荐文章：<http://blog.csdn.net/lmj623565791/article/details/38377229/>

## 详细分析：

请看`View.post`源码，

```java
public boolean post(Runnable action) {
    final AttachInfo attachInfo = mAttachInfo;
    if (attachInfo != null) {
        return attachInfo.mHandler.post(action);
    }
    // Assume that post will succeed later
    ViewRootImpl.getRunQueue().post(action);
    return true;
}
```

在`onCreate`的方法中执行的时候，`attachInfo==null`（为什么？请自行验证），所以post方法执行到了

```java
ViewRootImpl.getRunQueue().post(action)。
```

这个方法是将`action`先保存到`ViewRootImpl`中的一个静态队列中，保存起来什么时候用呢？

在`ViewRootImpl.perfromTravesals`方法中可以看到这个队列调用的代码，

```java
// Execute enqueued actions on every traversal in case a detached view enqueued an action
getRunQueue().executeActions(mAttachInfo.mHandler);
...
performMeasure(childWidthMeasureSpec, childHeightMeasureSpec);
...
performLayout(lp, mWidth, mHeight);
...
performDraw();
```

大家都知道`performTraversals`是布局遍历的方法，所以我们知道了，post的`Runnable`是在布局遍历的时候执行的。然而，它是在performMeasure、performLayout之前执行的。也就是说，这个`Runnable`是在View的测量和布局之前执行。View测量和布局完成之前是获取不到宽高的，那我们的`Runnable`是怎么获取到宽高的呢。

事实上，`getRunQueue().executeActions(mAttachInfo.mHandler)` 也不是直接执行这些`Runnable`，而是往主线程消息队列添加对应的消息进去，那么我们的这个消息执行的时机是怎么保证在View布局完成之后呢？研究过`performTraversals`源码的话，应该知道，`performTraversals`这个方法也是被附到一个消息上添加到消息队列等待执行的。下面看分析。

首先从View布局的终极方法`performTraversals`开始分析，这个方法到底是怎么执行的，在哪执行的。一路追过去，

```java
void doTraversal() {
    if (mTraversalScheduled) {
        mTraversalScheduled = false;
        mHandler.getLooper().getQueue().removeSyncBarrier(mTraversalBarrier);

        if (mProfile) {
            Debug.startMethodTracing("ViewAncestor");
        }

        performTraversals();

        if (mProfile) {
            Debug.stopMethodTracing();
            mProfile = false;
        }
    }
}
```

`perfromTraversals`由`doTraversal`调用，

```java
final class TraversalRunnable implements Runnable {
    @Override
    public void run() {
        doTraversal();
    }
}
```

而`doTraversal`方法在`TraversalRunnable`调用，那么这个`Runnable`的对象在哪执行的呢？

```java
final TraversalRunnable mTraversalRunnable = new TraversalRunnable();
```

可以看到，`mTraversalRunnable`出现在这个方法`scheduleTraversals`里：

```java
void scheduleTraversals() {
    if (!mTraversalScheduled) {
        mTraversalScheduled = true;
        mTraversalBarrier = mHandler.getLooper().getQueue().postSyncBarrier();
        mChoreographer.postCallback(
                Choreographer.CALLBACK_TRAVERSAL, mTraversalRunnable, null);
        if (!mUnbufferedInputDispatch) {
            scheduleConsumeBatchedInput();
        }
        notifyRendererOfFramePending();
        pokeDrawLockIfNeeded();
    }
```

这里面`mTraversalRunnable`也是被post了，这个post方法叫做`postCallback`，猜测是不是也是加到消息队列去了？

继续看`mChoreographer.postCallback`方法，这个方法最终会到下面这个方法中：

```java
private void postCallbackDelayedInternal(int callbackType,
        Object action, Object token, long delayMillis) {
    if (DEBUG_FRAMES) {
        Log.d(TAG, "PostCallback: type=" + callbackType
                + ", action=" + action + ", token=" + token
                + ", delayMillis=" + delayMillis);
    }

    synchronized (mLock) {
        final long now = SystemClock.uptimeMillis();
        final long dueTime = now + delayMillis;
        mCallbackQueues[callbackType].addCallbackLocked(dueTime, action, token);

        if (dueTime <= now) {
            scheduleFrameLocked(now);
        } else {
            Message msg = mHandler.obtainMessage(MSG_DO_SCHEDULE_CALLBACK, action);
            msg.arg1 = callbackType;
            msg.setAsynchronous(true);
            mHandler.sendMessageAtTime(msg, dueTime);
        }
    }
}
```

注意到熟悉的一句代码：`mHandler.sendMessageAtTime`，这个方法就是将消息加入到消息队列，而这个`Handler`对应的消息队列是什么？
我们从 `mHandler`这个对象着手，看看它是怎么来的。

```java
private Choreographer(Looper looper) {
    mLooper = looper;
    mHandler = new FrameHandler(looper);
    mDisplayEventReceiver = USE_VSYNC ? new FrameDisplayEventReceiver(looper) : null;
    mLastFrameTimeNanos = Long.MIN_VALUE;

    mFrameIntervalNanos = (long)(1000000000 / getRefreshRate());

    mCallbackQueues = new CallbackQueue[CALLBACK_LAST + 1];
    for (int i = 0; i <= CALLBACK_LAST; i++) {
        mCallbackQueues[i] = new CallbackQueue();
    }
}
```

在这个构造函数中，可以看到`mHandler`构造的时候传入一个`Looper`对象，那就要看下这个`Looper`是从哪里来的。

```java
// Thread local storage for the choreographer.
private static final ThreadLocal<Choreographer> sThreadInstance =
        new ThreadLocal<Choreographer>() {
    @Override
    protected Choreographer initialValue() {
        Looper looper = Looper.myLooper();
        if (looper == null) {
            throw new IllegalStateException("The current thread must have a looper!");
        }
        return new Choreographer(looper);
    }
};
```

这里又看到熟悉的代码了`Looper looper = Looper.myLooper();` 获取了当前线程（主线程）的`Looper`对象。

所以，`performTraversals`方法实际上也是被加入到消息队列中去执行的，而我们最初post的`Runnable`，是在`performTraversals`方法中将其附加到一个消息上并加入到消息队列里。所以，我们post的`Runnable`的消息，肯定是在`performTraversals`的消息之后执行的，也就是我们post的`Runnable`肯定是在`performTraversals`之后执行，而`performTraversals`之后，View的宽和高便计算出来了。

需要注意的是， 在`onCreate`（以及`onStart`, `onResume`）方法中必须保证是在主线程调用`View.post`方法，因为`ViewRootImpl.getRunQueue()`在不同线程获取到的是不同的对象（为什么？请研究`getRunQueue()`的类型），所以在`onCreate`方法内新建线程并在里面post的时候，这个post是成功不了的。在Android 7.0中修复了这个问题，也就说7.0系统中，在`onCreate`方法中新建线程并在里面post，这个`Runnable`是可以被执行到的。感兴趣的看源码。

## 一句话总结：

在`onCreate`中调用`View.post`的时候，post的`Runnable`被保存起来，在下一次遍历布局的时候重新加到消息队列里（Android 7.0是在attach window的时候重新加到消息队列里），而且布局遍历本身也是加到消息队列执行的，所以我们post的`Runnable`所在的消息肯定是在布局遍历之后，所以在`Runnable`里必定可以获取到正确的宽高。
