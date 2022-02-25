/*
 * Copyright 2018, 2019, 2020 Dooboolab.
 *
 * This file is part of Flutter-Sound.
 *
 * Flutter-Sound is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License version 3 (LGPL-V3), as published by
 * the Free Software Foundation.
 *
 * Flutter-Sound is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with Flutter-Sound.  If not, see <https://www.gnu.org/licenses/>.
 */

/// ------------------------------------------------------------------
///
/// # [SoundPlayerUI] is a HTML 5 style audio play bar.
/// It allows you to play/pause/resume and seek an audio track.
///
/// The `SoundPlayerUI` displays:
/// -  a spinner while loading audio
/// -  play/resume buttons
/// -  a slider to indicate and change the current play position.
/// -  optionally displays the album title and track if the
///   [Track] contains those details.
///
/// ------------------------------------------------------------------
///
/// {@category UI_Widgets}
library ui_player;

import 'dart:async';

import 'recorder_playback_controller.dart' as current;
import 'package:flutter/material.dart';
import 'package:flutter_sound_lite/flutter_sound.dart';
import 'package:logger/logger.dart' show Level, Logger;
import 'package:provider/provider.dart';

///
typedef OnLoad = Future<Track> Function(BuildContext context);

/// -----------------------------------------------------------------
/// # A HTML 5 style audio play bar.
///
/// Allows you to play/pause/resume and seek an audio track.
/// The `SoundPlayerUI` displays:
/// -  a spinner while loading audio
/// -  play/resume buttons
/// -  a slider to indicate and change the current play position.
/// -  optionally displays the album title and track if the
///   [Track] contains those details.
///
/// -----------------------------------------------------------------
///
class SoundPlayerUI extends StatefulWidget {
  /// only codec support by android unless we have a minSdk of 29
  /// then OGG_VORBIS and OPUS are supported.
  static const Codec standardCodec = Codec.aacADTS;
  static const int _barHeight = 40;

  final OnLoad? _onLoad;

  final Track? _track;

  final bool _enabled;

  final Color? _backgroundColor;
  final Color _iconColor;
  final Color _disabledIconColor;
  final TextStyle? _textStyle;
  final TextStyle? _titleStyle;
  final SliderThemeData? _sliderThemeData;

  final String id;

  SoundPlayerUI.fromLoader(
    OnLoad onLoad, {
    bool showTitle = false,
    bool enabled = true,
    AudioFocus audioFocus = AudioFocus.requestFocusAndKeepOthers,
    Color? backgroundColor,
    Color iconColor = Colors.black,
    Color disabledIconColor = Colors.grey,
    TextStyle? textStyle,
    TextStyle? titleStyle,
    required this.id,
    SliderThemeData? sliderThemeData,
  })  : _onLoad = onLoad,
        _track = null,
        _enabled = enabled,
        _backgroundColor = (backgroundColor == null) ? Color(0xFFFAF0E6) : backgroundColor,
        _iconColor = iconColor,
        _disabledIconColor = disabledIconColor,
        _textStyle = textStyle,
        _titleStyle = titleStyle,
        _sliderThemeData = sliderThemeData;

  @override
  State<StatefulWidget> createState() {
    return SoundPlayerUIState(
      _track,
      _onLoad,
      enabled: _enabled,
      backgroundColor: (_backgroundColor != null) ? _backgroundColor : Color(0xFFFAF0E6),
      iconColor: _iconColor,
      disabledIconColor: _disabledIconColor,
      textStyle: _textStyle,
      titleStyle: _titleStyle,
      sliderThemeData: _sliderThemeData,
      id: id,
    );
  }
}

// ------------------------------------------------------------------------------------------------------------------

/// internal state.
/// @nodoc
class SoundPlayerUIState extends State<SoundPlayerUI> {
  final Logger _logger = Logger(level: Level.debug);

  late FlutterSoundPlayer? _player;

  final _sliderPosition = _SliderPosition();

  /// we keep our own local stream as the players come and go.
  /// This lets our StreamBuilder work without  worrying about
  /// the player's stream changing under it.
  final StreamController<PlaybackDisposition> _localController;

  // we are current play (but may be paused)
  _PlayState __playState = _PlayState.stopped;

  // Indicates that we have start a transition (play to pause etc)
  // and we should block user interaction until the transition completes.
  bool __transitioning = false;

  /// indicates that we have started the player but we are waiting
  /// for it to load the audio resource.
  bool __loading = false;

  /// the [Track] we are playing .
  /// If the fromLoader ctor is used this will be null
  /// until the user clicks the Play button and onLoad
  /// returns a non null [Track]
  Track? _track;

  final OnLoad? _onLoad;

  final bool? _enabled;

  final Color? _backgroundColor;

  final Color? _iconColor;

  final Color? _disabledIconColor;

  StreamSubscription? _playerSubscription; // ignore: cancel_subscriptions

  final SliderThemeData? _sliderThemeData;

  final String id;

  ///
  SoundPlayerUIState(
    this._track,
    this._onLoad, {
    bool? enabled,
    Color? backgroundColor,
    Color? iconColor,
    Color? disabledIconColor,
    TextStyle? textStyle,
    TextStyle? titleStyle,
    SliderThemeData? sliderThemeData,
    required String id,
  })  : _player = FlutterSoundPlayer(id: id),
        _enabled = enabled,
        _backgroundColor = backgroundColor,
        _iconColor = iconColor,
        _disabledIconColor = disabledIconColor,
        _sliderThemeData = sliderThemeData,
        id = id,
        _localController = StreamController<PlaybackDisposition>.broadcast() {

    _sliderPosition.position = Duration(seconds: 0);
    _sliderPosition.maxPosition = Duration(seconds: 0);
    if (!_enabled!) {
      __playState = _PlayState.disabled;
    }
    _player!
        .openAudioSession(
            focus: AudioFocus.requestFocusAndDuckOthers,
            category: SessionCategory.playAndRecord,
            mode: SessionMode.modeDefault,
            device: AudioDevice.speaker,
            audioFlags: outputToSpeaker | allowBlueToothA2DP | allowAirPlay,
            withUI: true)
        .then((_) {
      _setCallbacks();
      _player!.setSubscriptionDuration(Duration(milliseconds: 100));
    });
  }

  /// We can play if we have a non-zero duration or we are dynamically
  /// loading tracks via _onLoad.
  Future<bool> get canPlay async {
    return _onLoad != null || (_track != null /* && TODO (_track.length > 0)*/);
  }

  /// detect hot reloads when debugging and stop the player.
  /// If we don't the platform specific code keeps running
  /// and sending methodCalls to a slot that no longer exists.
  @override
  void reassemble() async {
    super.reassemble();
    if (_track != null) {
      if (_playState != _PlayState.stopped) {
        await stop();
      }
      // TODO ! trackRelease(_track);
    }
    //Log.d('Hot reload releasing plugin');
    //_player.release();
  }

  ///
  @override
  Widget build(BuildContext context) {
    current.registerPlayer(context, this);
    return  _buildPlayBar();
  }

  void _setCallbacks() {
    /// TODO
    /// should we chain these events in case the user of our api
    /// also wants to see these events?

    /// pipe the new sound players stream to our local controller.

    _player!.dispositionStream()!.listen(_localController.add);

  }

  void _onStopped() {
    onPlaybackEnd(context);
    setState(() {
      /// we can get a race condition when we stop the playback
      /// We have disabled the button and called stop.
      /// The OS then sends an onStopped call which tries
      /// to put the state into a stopped state overriding
      /// the disabled state.
      if (_playState != _PlayState.disabled) {
        _playState = _PlayState.stopped;
      }
    });
  }

  /// This method is used by the RecorderPlaybackController to attached
  /// the [_localController] to the `SoundRecordUI`'s stream.
  /// This is only done when this player is attached to a
  /// RecorderPlaybackController.
  ///
  /// When recording starts we are attached to the recorderStream.
  /// When recording finishes this method is called with a null and we
  /// revert to the [_player]'s stream.

  void connectRecorderStream(Stream<PlaybackDisposition>? recorderStream) {
    if (recorderStream != null) {
      recorderStream.listen(_localController.add);
    } else {
      /// revert to piping the player
      _player!.dispositionStream()!.listen(_localController.add);
    }
  }

  ///
  @override
  void dispose() {
    _stop(supressState: true);
    _player!.closeAudioSession();
    _player = null;
    super.dispose();
  }

  Widget _buildPlayBar() {
    return Container(
      height: 40,
      decoration:
          BoxDecoration(color: _backgroundColor, borderRadius: BorderRadius.circular(SoundPlayerUI._barHeight / 2)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8,
          ),
          _buildPlayButton(id),
          SizedBox(
            width: 8,
          ),
          _buildSlider(),
          SizedBox(
            width: 8,
          ),
        ],
      ),
    );
  }

  /// Returns the players current state.
  _PlayState get _playState {
    return __playState;
  }

  set _playState(_PlayState state) {
    setState(() => __playState = state);
  }

  /// Controls whether the Play button is enabled or not.
  /// Can not toggle this whilst the player is playing or paused.
  void playbackEnabled({required bool enabled}) {
    if (__playState != _PlayState.playing && __playState != _PlayState.paused) {
      setState(() {
        if (enabled == true) {
          __playState = _PlayState.stopped;
        } else if (enabled == false) {
          __playState = _PlayState.disabled;
        }
      });
    } else {
      // if for whatever reason the player is active, we simply stop and reset here, then try again.
      stop().then((x) {
        setState(() {
          if (enabled == true) {
            __playState = _PlayState.stopped;
          } else if (enabled == false) {
            __playState = _PlayState.disabled;
          }
        });
      });
    }
  }

  /// Called when the user clicks  the Play/Pause button.
  /// If the audio is paused or stopped the audio will start
  /// playing.
  /// If the audio is playing it will be paused.
  ///
  /// see [play] for the method to programmitcally start
  /// the audio playing.
  void _onPlay(BuildContext localContext) {
    switch (_playState) {
      case _PlayState.stopped:
        play();
        break;
      case _PlayState.playing:
        // stop the player
        pause();
        break;
      case _PlayState.paused:
        // stop the player
        resume();
        break;
      case _PlayState.disabled:
        // shouldn't be possible as play button is disabled.
        stop();
        break;
    }
  }

  /// Call [resume] to resume playing the audio.
  void resume() {
    setState(() {
      onPlaybackStart(context);
      _transitioning = true;
      _playState = _PlayState.playing;
    });

    _player!.resumePlayer().then((_) => _transitioning = false).catchError((dynamic e) {
      _logger.w('Error calling resume ${e.toString()}');
      _playState = _PlayState.stopped;
      _player!.stopPlayer();
      return false;
    }).whenComplete(() => _transitioning = false);
  }

  /// Call [pause] to pause playing the audio.
  void pause() {
    // pause the player
    setState(() {
      onPlaybackEnd(context);
      _transitioning = true;
      _playState = _PlayState.paused;
    });

    _player!.pausePlayer().then((_) => _transitioning = false).catchError((dynamic e) {
      _logger.w('Error calling pause ${e.toString()}');
      _playState = _PlayState.playing;
      _playState = _PlayState.stopped;
      _player!.stopPlayer();
      return false;
    }).whenComplete(() => _transitioning = false);
  }

  /// start playback.
  void play() async {
    _transitioning = true;
    _loading = true;
    _logger.d('Loading starting');

    _logger.d('Calling play');

    await _localController.close();

    if (_track != null && _player!.isPlaying) {
      _logger.d('play called whilst player running. Stopping Player first.');
      await _stop();
    }

    Future<Track> newTrack;

    if (_onLoad != null) {
      if (_track != null) {
        // TODO trackRelease(_track);
      }

      /// dynamically load the player.
      newTrack = _onLoad!(context);
    } else {
      newTrack = Future.value(_track);
    }

    /// no track then just silently ignore the start action.
    /// This means that _onLoad returned null and the user
    /// can display appropriate errors.
    _track = await newTrack;
    if (_track != null) {
      _start();
    } else {
      _loading = false;
      _transitioning = false;
    }
  }

  /// internal start method.
  void _start() async {
    var trck = _track;
    if (trck != null) {

      await _player!.startPlayerFromTrack(trck, whenFinished: _onStopped).then((_) {
        _playState = _PlayState.playing;
        onPlaybackStart(context);
      }).catchError((dynamic e) {
        _logger.w('Error calling play() ${e.toString()}');
        _playState = _PlayState.stopped;
        return null;
      }).whenComplete(() {
        _loading = false;
        _transitioning = false;
        _logger.d('Transitioning = false');
      });
    }
  }

  /// Call [stop] to stop the audio playing.
  ///
  Future<void> stop() async {
    await _stop();
  }

  ///
  /// interal stop method.
  ///
  Future<void> _stop({bool supressState = false}) async {
    if (_player!.isPlaying || _player!.isPaused) {
      onPlaybackEnd(context);
      await _player!.stopPlayer().then<void>((_) {
        if (_playerSubscription != null) {
          _playerSubscription!.cancel();
          _playerSubscription = null;
        }
        setState(() {});
      });
    }

    // if called via dispose we can't trigger setState.
    if (supressState) {
      __playState = _PlayState.stopped;
      __transitioning = false;
      __loading = false;
    } else {
      _playState = _PlayState.stopped;
      _transitioning = false;
      _loading = false;
    }

    _sliderPosition.position = Duration.zero;
  }

  /// put the ui into a 'loading' state which
  /// will start the spinner.
  set _loading(bool value) {
    setState(() => __loading = value);
  }

  /// current loading state.
  bool get _loading {
    return __loading;
  }

  /// When we are moving between states we mark
  /// ourselves as 'transition' to block other
  /// transitions.
  // ignore: avoid_setters_without_getters
  set _transitioning(bool value) {
    _logger.d('Transitioning = $value');
    setState(() => __transitioning = value);
  }

  /// Build the play button which includes the loading spinner and pause button
  ///
  Widget _buildPlayButton(String id) {
    Widget? button;

    if (_loading == true) {
      button = Container(
        /// use a tick builder so we don't show the spinkit unless
        /// at least 100ms has passed. This stops a little flicker
        /// of the spiner caused by the default loading state.
        child: StreamBuilder<PlaybackDisposition>(
          stream: _localController.stream,
          initialData: PlaybackDisposition(
            id: id,
            duration: Duration(seconds: 0),
            position: Duration(seconds: 0),
          ),
          builder: (context, asyncData) {
            return Padding(
              padding: const EdgeInsets.all(8.0),
              child: CircularProgressIndicator(strokeWidth: 5, value: 0.0),
            );
          },
        ),
      );
    } else {
      button = _buildPlayButtonIcon(button);
    }
    return Container(
      width: 30,
      child: FutureBuilder<bool>(
        future: canPlay,
        builder: (context, asyncData) {
          var _canPlay = false;
          if (asyncData.connectionState == ConnectionState.done) {
            _canPlay = asyncData.data! && !__transitioning;
          }

          return Theme(
            data: ThemeData(
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
            ),
            child: InkWell(
              onTap: _canPlay &&
                      (_playState == _PlayState.stopped ||
                          _playState == _PlayState.playing ||
                          _playState == _PlayState.paused)
                  ? () {
                      return _onPlay(context);
                    }
                  : null,
              child: button,
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlayButtonIcon(Widget? widget) {
    if (_playState == _PlayState.disabled) {
      widget = _GrayedOut(grayedOut: true, child: widget = Icon(Icons.play_arrow, color: _disabledIconColor));
    } else {
      widget = FutureBuilder<bool>(
          future: canPlay,
          builder: (context, asyncData) {
            bool? canPlay = false;
            if (asyncData.connectionState == ConnectionState.done) {
              canPlay = asyncData.data;
            }
            return Icon(_player!.isStopped || _player!.isPaused ? Icons.play_arrow : Icons.stop,
                color: canPlay! ? _iconColor : _disabledIconColor);
          });
    }
    //break;
    return SizedBox(height: 40, width: 24, child: widget);
  }

  //'${Format.duration(disposition.position, showSuffix: false)}'
  //' / '
  //'${Format.duration(disposition.duration)}',

  /// Specialised method that allows the RecorderPlaybackController
  /// to update our duration as a recording occurs.
  ///
  /// This method should be used for no other purposes.
  ///
  /// During normal playback the [StreamBuilder] used
  /// in [_buildDuration] is responsible for updating the duration.
  // void _updateDuration(Duration duration) {
  //   /// push the update to the next build cycle as this can
  //   /// be called during a build cycle which flutter won't allow.
  //   Future.delayed(Duration.zero,
  //       () => setState(() => _sliderPosition.maxPosition = duration));
  // }

  Widget _buildSlider() {
    return Expanded(
        child: PlaybarSlider(
      _localController.stream,
      (position) {
        _sliderPosition.position = position;
        if (_player!.isPlaying || _player!.isPaused) {
          _player!.seekToPlayer(position);
        }
      },
      _sliderThemeData,
      id,
    ));
  }
}

/// Describes the state of the playbar.
enum _PlayState {
  /// stopped
  stopped,

  ///
  playing,

  ///
  paused,

  ///
  disabled
}

/// GreyedOut optionally grays out the given child widget.
/// [child] the child widget to display
/// If [greyedOut] is true then the child will be grayed out and
/// any touch activity over the child will be discarded.
/// If [greyedOut] is false then the child will displayed as normal.
/// The [opacity] setting controls the visiblity of the child
/// when it is greyed out. A value of 1.0 makes the child fully visible,
/// a value of 0.0 makes the child fully opaque.
/// The default value of [opacity] is 0.3.
class _GrayedOut extends StatelessWidget {
  ///
  final Widget child;

  ///
  final bool grayedOut;

  ///
  final double opacity;

  ///
  _GrayedOut({required this.child, this.grayedOut = true}) : opacity = grayedOut == true ? 0.3 : 1.0;

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(absorbing: grayedOut, child: Opacity(opacity: opacity, child: child));
  }
}

///
class PlaybarSlider extends StatefulWidget {
  final void Function(Duration position) _seek;

  ///
  final Stream<PlaybackDisposition> stream;

  final SliderThemeData? _sliderThemeData;

  final String id;

  ///
  PlaybarSlider(
    this.stream,
    this._seek,
    this._sliderThemeData,
    this.id,
  );

  @override
  State<StatefulWidget> createState() {
    return _PlaybarSliderState(id);
  }
}

///
class _PlaybarSliderState extends State<PlaybarSlider> {
  final String id;
  late PlaybackDisposition prevData;

  _PlaybarSliderState(this.id){
    prevData = PlaybackDisposition(
      id: id,
      duration: Duration(seconds: 0),
      position: Duration(seconds: 0),
    );
  }

  @override
  Widget build(BuildContext context) {

    SliderThemeData? sliderThemeData;
    if (widget._sliderThemeData == null) {
      sliderThemeData = SliderTheme.of(context);
    } else {
      sliderThemeData = widget._sliderThemeData;
    }
    return SliderTheme(
      data: sliderThemeData!.copyWith(
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6.0),
      ),
      child: StreamBuilder<PlaybackDisposition>(
        stream: widget.stream,
        initialData: PlaybackDisposition(
          id: id,
          duration: Duration(seconds: 0),
          position: Duration(seconds: 0),
        ),
        builder: (context, snapshot) {
          var disposition = snapshot.data!;
          if (disposition.id == id) {
            prevData = disposition;
            return Slider(
              max: disposition.duration.inMilliseconds.toDouble(),
              value: disposition.position.inMilliseconds.toDouble(),
              onChanged: (value) => widget._seek(Duration(milliseconds: value.toInt())),
            );
          }else{
            print("1111111111111"+id + ' ' + disposition.id);
          }

          return Slider(
            max: prevData.duration.inMilliseconds.toDouble(),
            value: prevData.position.inMilliseconds.toDouble(),
            onChanged: (value) => widget._seek(Duration(milliseconds: value.toInt())),
          );
        },
      ),
    );
  }
}

///
class _SliderPosition  {
  /// The current position of the slider.
  Duration _position = Duration.zero;

  /// The max position of the slider.
  Duration maxPosition = Duration.zero;

  bool _disposed = false;

  ///
  set position(Duration position) {
    _position = position;
  }

  @override
  void dispose() {
    _disposed = true;
  }

  ///
  Duration get position {
    return _position;
  }
}
