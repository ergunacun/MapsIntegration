import 'dart:async';

import 'package:data/service/serverResponses/googleMapsResponse.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:location/location.dart';
import 'package:paysure/services/googleMapsService.dart';
import 'package:paysure/utils/assetUtils.dart';
import 'package:paysure/utils/distanceUtils.dart';

class GoogleMapsWidget extends StatefulWidget {
  final OnPlaceSelected onPlaceSelected;
  GoogleMapsWidget({
    Key? key,
    required this.onPlaceSelected,
  }) : super(key: key);

  @override
  _GoogleMapsWidgetState createState() => _GoogleMapsWidgetState(this.onPlaceSelected);
}

typedef OnPlaceSelected = void Function(GooglePlace selectedPlace);

class _GoogleMapsWidgetState extends State<GoogleMapsWidget> {
  OnPlaceSelected? _onPlaceSelected;
  // Google maps properties
  static LatLng? _lastKnownUserLocation;
  GoogleMapController? _mapController;
  String? _mapStyle;
  bool _mapStyleInitialized = false;
  final LatLng _center = const LatLng(51.50018066227123, -0.12405818324922431); // Default center is London

  //Map<String, Marker> _markers = <String, Marker>{};

  late ProvidersHandler _providersHandler;
  late SearchHandler _searchHandler;

  // Providers list
  var _providerListPageController = PageController(viewportFraction: 0.9);

  // Search properties
  Timer? _debounceText;
  var _searchProviderTextController = TextEditingController();

  _GoogleMapsWidgetState(OnPlaceSelected onPlaceSelected) {
    this._onPlaceSelected = onPlaceSelected;
  }

  @override
  void initState() {
    super.initState();

    _providersHandler = ProvidersHandler(this);
    _searchHandler = SearchHandler(this);

    // Load map style from asset
    rootBundle.loadString('assets/map_style.txt').then((string) {
      _mapStyle = string;
      _refreshMapStyle();
    });
  }

  @override
  void dispose() {
    print("DISPOSEEEEE - Providers tab");
    if (_mapController != null) {
      _mapController!.dispose();
    }
    _providerListPageController.dispose();
    _debounceText?.cancel();
    _searchProviderTextController.dispose();
    _providersHandler.dispose();
    _searchHandler.dispose();
    super.dispose();
  }

  void refreshState() {
    setState(() {});
  }

  // Refresh map style once we have style loaded from asset and google maps initialized
  void _refreshMapStyle() {
    if (!_mapStyleInitialized && _mapStyle != null && _mapController != null) {
      setState(() {
        _mapController!.setMapStyle(_mapStyle);
        _mapStyleInitialized = true;
      });
    }
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;

    AssetUtils.getBytesFromAsset('assets/imgs/map_marker.png', 100).then((markerIcon) {
      setState(() {
        _providersHandler.googleMapsMarkerIcon = BitmapDescriptor.fromBytes(markerIcon);
      });

      AssetUtils.getBytesFromAsset('assets/imgs/map_marker_highlighted.png', 120).then((markerIcon) {
        setState(() {
          _providersHandler.googleMapsHighlightedMarkerIcon = BitmapDescriptor.fromBytes(markerIcon);
        });
        // After map is being created, refresh map style
        _refreshMapStyle();

        // Get current user location and move maps there
        _moveMapsCameraToCurrentLocation();
      });
    });
  }

  void _onCameraIdle() {
    _mapController!.getVisibleRegion().then((LatLngBounds visibleRegion) {
      LatLng currentMapCenter = LatLng(
        (visibleRegion.northeast.latitude + visibleRegion.southwest.latitude) / 2,
        (visibleRegion.northeast.longitude + visibleRegion.southwest.longitude) / 2,
      );

      this._providersHandler.populateFromGoogle(currentMapCenter, visibleRegion);
    });
  }

  void _moveMapsCameraToCurrentLocation() async {
    // 1. Get current user location
    Location location = Location();
    bool _serviceEnabled;
    PermissionStatus _permissionGranted;

    _serviceEnabled = await location.serviceEnabled();
    if (!_serviceEnabled) {
      _serviceEnabled = await location.requestService();
      if (!_serviceEnabled) {
        return;
      }
    }

    _permissionGranted = await location.hasPermission();
    if (_permissionGranted == PermissionStatus.denied) {
      _permissionGranted = await location.requestPermission();
      if (_permissionGranted != PermissionStatus.granted) {
        return;
      }
    }

    LocationData _locationData = await location.getLocation();

    // 2. Remember last known user location
    _lastKnownUserLocation = LatLng(_locationData.latitude!, _locationData.longitude!);

    // 2. Move maps camera to show my location
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(
          target: LatLng(_locationData.latitude!, _locationData.longitude!),
          zoom: 14,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        generateGoogleMapsWidget(),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: EdgeInsets.only(bottom: 10.0),
            child: generateBottomProvidersList(),
          ),
        ),
        generateSearchBoxWidget(),
      ],
    );
  }

  Widget generateSearchBoxWidget() {
    return Stack(
      children: [
        generateSearchBackground(),
        Container(
          margin: EdgeInsets.only(
            top: 12.0,
            left: 12.0,
            right: 12.0,
          ),
          child: Column(
            children: [
              TextFormField(
                controller: _searchProviderTextController,
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  suffixIcon: IconButton(
                    onPressed: () {
                      _searchProviderTextController.clear();
                      _searchHandler.clear();
                      setState(() {});
                    },
                    icon: Icon(Icons.clear),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24.0),
                    borderSide: BorderSide(
                      color: Colors.black26,
                      width: 0.5,
                    ),
                  ),
                  //labelText: "Search for providers",
                  fillColor: Colors.white,
                  filled: true,
                  hintText: "Search Providers",
                  //counterText: "We found 34 providers near you",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24.0),
                    borderSide: BorderSide(),
                  ),
                ),
                keyboardType: TextInputType.text,
                onChanged: (text) {
                  // Debounce text
                  if (_debounceText?.isActive ?? false) {
                    _debounceText!.cancel();
                  }
                  _debounceText = Timer(const Duration(milliseconds: 800), () {
                    // Search nerby locations.
                    // If we have users location, search based on it.
                    // Otherwise, take center of the map
                    if (_lastKnownUserLocation != null) {
                      _searchHandler.searchForText(text, _lastKnownUserLocation!);
                    } else {
                      // Calculate center of the map
                      _mapController!.getVisibleRegion().then((LatLngBounds visibleRegion) {
                        LatLng currentMapCenter = LatLng(
                          (visibleRegion.northeast.latitude + visibleRegion.southwest.latitude) / 2,
                          (visibleRegion.northeast.longitude + visibleRegion.southwest.longitude) / 2,
                        );

                        _searchHandler.searchForText(text, currentMapCenter);
                      });
                    }
                  });
                },
              ),
              Expanded(
                child: Container(
                  child: LayoutBuilder(builder: (BuildContext context, BoxConstraints constraints) {
                    return generateSearchPanel(constraints);
                  }),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget generateSearchBackground() {
    var enteredText = _searchProviderTextController.text;
    bool hide = (enteredText == null || enteredText.trim().isEmpty);

    return LayoutBuilder(builder: (context, size) {
      return AnimatedContainer(
        height: hide ? 0.0 : size.maxHeight,
        color: Colors.white,
        curve: Curves.easeInSine,
        duration: Duration(milliseconds: 300),
      );
    });
  }

  Widget generateSearchPanel(BoxConstraints constraints) {
    var height;
    var enteredText = _searchProviderTextController.text;
    if (enteredText == null || enteredText.trim().isEmpty) {
      height = 0.0;
    } else {
      height = constraints.maxHeight;
    }

    if (enteredText != null) {
      enteredText = enteredText.trim();
    }

    bool searchResultsAreVisible = enteredText != null && enteredText.isNotEmpty;

    return AnimatedContainer(
      curve: Curves.easeIn,
      height: height,
      duration: Duration(
        milliseconds: 300,
      ),
      child: searchResultsAreVisible
          ? Column(
              children: [
                SizedBox(
                  height: 12.0,
                ),
                _searchHandler.providersLoading
                    ? Text(
                        "Searching...",
                      )
                    : Text(
                        "Results for: " + enteredText,
                      ),
                SizedBox(
                  height: 4.0,
                ),
                Expanded(
                  child: ListView.builder(
                      itemCount: _searchHandler.providers.length,
                      itemBuilder: (context, index) {
                        GooglePlace provider = _searchHandler.providers[index];

                        return GooglePlaceInfoWidget(
                          provider: provider,
                          providerIcon: Image(
                            image: AssetImage("assets/imgs/tmp_provider_thumb.png"),
                            fit: BoxFit.contain,
                            height: 50.0,
                          ),
                          decoration: null,
                          rightIcon: Icon(
                            Icons.arrow_forward_ios,
                            size: 13,
                          ),
                          onPlaceSelected: this._onPlaceSelected,
                        );
                      }),
                ),
              ],
            )
          : SizedBox(),
    );
  }

  Container generateGoogleMapsWidget() {
    return Container(
      child: GoogleMap(
        markers: Set<Marker>.of(_providersHandler.markers.values),
        onMapCreated: _onMapCreated,
        onCameraIdle: _onCameraIdle,
        mapType: MapType.normal,
        buildingsEnabled: false,
        trafficEnabled: false,
        indoorViewEnabled: false,
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: true,
        zoomGesturesEnabled: true,
        initialCameraPosition: CameraPosition(
          target: _lastKnownUserLocation == null ? _center : _lastKnownUserLocation!,
          zoom: 14.0,
        ),
      ),
    );
  }

  Widget generateBottomProvidersList() {
    //_controller = PageController(viewportFraction: 0.8);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          height: 70.0,
          child: PageView.builder(
            onPageChanged: (index) {
              _providersHandler.selectProviderWithIndex(index);
            },
            itemCount: _providersHandler.providers.length,
            // store this controller in a State to save the carousel scroll position
            controller: _providerListPageController,
            itemBuilder: (BuildContext context, int itemIndex) {
              GooglePlace provider = _providersHandler.providers[itemIndex];
              return GooglePlaceInfoWidget(
                provider: provider,
                providerIcon: Image(
                  image: AssetImage("assets/imgs/tmp_provider_thumb.png"),
                  fit: BoxFit.contain,
                  height: 50.0,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.all(
                    Radius.circular(8.0),
                  ),
                  border: Border.all(
                    color: Colors.black87,
                    style: BorderStyle.solid,
                    width: 1.0,
                  ),
                ),
                onPlaceSelected: this._onPlaceSelected,
              );
            },
          ),
        )
      ],
    );
  }

  void animateToPageIndex(selectedPlaceIndex) {
    _providerListPageController.animateToPage(
      selectedPlaceIndex,
      curve: Curves.easeInSine,
      duration: Duration(milliseconds: 300),
    );
  }
}

// https://stackoverflow.com/questions/51607440/horizontally-scrollable-cards-with-snap-effect-in-flutter
class CustomPageController extends PageController {
  @override
  void dispose() {
    print("Controller is disposed");
    super.dispose();
  }
}

class GooglePlaceInfoWidget extends StatelessWidget {
  final GooglePlace provider;
  final Image? providerIcon;
  final BoxDecoration? decoration;
  final Icon? rightIcon;
  final OnPlaceSelected? onPlaceSelected;

  const GooglePlaceInfoWidget({
    Key? key,
    required this.provider,
    required this.decoration,
    this.providerIcon,
    this.rightIcon,
    required this.onPlaceSelected,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    bool hasDistanceInKm = provider.distanceFromMeInKm != null;
    String distanceInKmStr = "";
    if (hasDistanceInKm) {
      distanceInKmStr = NumberFormat("#,##0.0", "en_US").format(provider.distanceFromMeInKm);
    }

    return InkWell(
      onTap: () {
        // Close keyboard
        FocusScope.of(context).unfocus();

        // Notify that place is selected
        if (this.onPlaceSelected != null) {
          this.onPlaceSelected!(this.provider);
        }
      },
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 4.0),
        child: Container(
          decoration: this.decoration,
          child: Container(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                children: [
                  providerIcon != null ? providerIcon! : SizedBox(),
                  providerIcon != null
                      ? SizedBox(
                          width: 4.0,
                        )
                      : SizedBox(),
                  Expanded(
                    child: Container(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            provider.name!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            provider.vicinity!,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.black54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  hasDistanceInKm
                      ? Container(
                          width: 50.0,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  distanceInKmStr,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  "km",
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.black54,
                                  ),
                                )
                              ],
                            ),
                          ),
                        )
                      : SizedBox(),
                  rightIcon != null ? rightIcon! : SizedBox(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SearchHandler {
  _GoogleMapsWidgetState? parentComponent;
  late GoogleMapsService _googleMapsApiService;
  List<GooglePlace> providers = [];
  bool providersLoading = false;

  SearchHandler(_GoogleMapsWidgetState parentComponent) {
    this.providers = [];
    this.parentComponent = parentComponent;
    this._googleMapsApiService = GoogleMapsService();
  }

  void dispose() {
    this.parentComponent = null;
  }

  void clear() {
    this.providers = [];
    this.parentComponent!.refreshState();
  }

  void searchForText(String text, LatLng nearByLocation) {
    // Clear list of providers
    this.providers = [];
    this.providersLoading = true;
    this.parentComponent!.refreshState();
    //
    // Load places from google
    _googleMapsApiService.searchPlacesNearBy(nearByLocation, text).then((googleResponse) {
      //
      // Take places from response
      List<GooglePlace> places = googleResponse == null || googleResponse.results == null ? [] : googleResponse.results!;

      // Add places into list of all places
      places.forEach((place) {
        if (_GoogleMapsWidgetState._lastKnownUserLocation != null) {
          var placeLocation = LatLng(
            place.geometry!.location!.lat!,
            place.geometry!.location!.lng!,
          );
          place.distanceFromMeInKm = DistanceUtils.getDistanceBetweenLocations(
            _GoogleMapsWidgetState._lastKnownUserLocation!,
            placeLocation,
          );
        }
      });
      providers = places;
      this.providersLoading = false;

      //Refresh parent control
      this.parentComponent!.refreshState();
    });
  }
}

class ProvidersHandler {
  _GoogleMapsWidgetState? parentComponent;
  late GoogleMapsService _googleMapsApiService;
  Map<String?, GooglePlace> _allLoadedPlaces = <String?, GooglePlace>{};
  List<GooglePlace> providers = [];
  Map<String?, Marker> markers = <String?, Marker>{};

  late BitmapDescriptor googleMapsMarkerIcon;
  late BitmapDescriptor googleMapsHighlightedMarkerIcon;
  String? _selectedPlaceId;

  Timer? _markerRefreshTimer;

  ProvidersHandler(_GoogleMapsWidgetState parentComponent) {
    this.parentComponent = parentComponent;
    _googleMapsApiService = GoogleMapsService();
  }

  void dispose() {
    _markerRefreshTimer?.cancel();
    this.parentComponent = null;
  }

  void populateFromGoogle(LatLng currentMapCenter, LatLngBounds visibleRegion) {
    this.providers = [];
    this.parentComponent!.refreshState();
    //
    // Load places from google
    _googleMapsApiService.searchPlacesNearBy(currentMapCenter, "").then((googleResponse) {
      //
      // Take places from response
      List<GooglePlace>? places = googleResponse == null || googleResponse.results == null ? [] : googleResponse.results;

      // Add places into list of all places
      if (places != null) {
        places.forEach((place) {
          if (_GoogleMapsWidgetState._lastKnownUserLocation != null) {
            var placeLocation = LatLng(
              place.geometry!.location!.lat!,
              place.geometry!.location!.lng!,
            );
            place.distanceFromMeInKm = DistanceUtils.getDistanceBetweenLocations(
              _GoogleMapsWidgetState._lastKnownUserLocation!,
              placeLocation,
            );
          }

          _allLoadedPlaces[place.placeId] = place;
        });
      }

      // Filter out only those which are visible on google maps
      List<GooglePlace> placesFromVisibleRegion = [];
      _allLoadedPlaces.values.forEach((googlePlace) {
        var placeLocation = LatLng(googlePlace.geometry!.location!.lat!, googlePlace.geometry!.location!.lng!);
        if (visibleRegion.contains(placeLocation)) {
          placesFromVisibleRegion.add(googlePlace);
        }
      });

      providers = placesFromVisibleRegion;
      generateMarkers(true);
    });
  }

  selectProviderWithIndex(int index) {
    // Refresh parent component
    if (_markerRefreshTimer?.isActive ?? false) {
      _markerRefreshTimer!.cancel();
    }
    _markerRefreshTimer = Timer(const Duration(milliseconds: 300), () {
      // Take selected provider and its placeId
      GooglePlace selectedProvider = this.providers.elementAt(index);
      _selectedPlaceId = selectedProvider.placeId;

      // Refresh look of markers
      this.providers.forEach((provider) {
        var marker = _generateMarkerForProvider(provider);
        this.markers[provider.placeId] = marker;
      });

      this.parentComponent!.refreshState();
    });
  }

  void generateMarkers(bool animateProviderToAPage) {
    // Check do we have selected place among places
    bool foundSelectedPlaceAmongPlaces = false;

    late var _selectedPlaceIndex;
    int counter = -1;
    providers.forEach((element) {
      counter++;
      if (element.placeId == _selectedPlaceId) {
        foundSelectedPlaceAmongPlaces = true;
        _selectedPlaceIndex = counter;
      }
    });

    // If we couldnt find selected place among places, clear it
    if (!foundSelectedPlaceAmongPlaces) {
      _selectedPlaceId = null;
    }

    // If there is no selected place and we have providers, select first one
    if (_selectedPlaceId == null && this.providers.isNotEmpty) {
      _selectedPlaceId = this.providers.elementAt(0).placeId;
      _selectedPlaceIndex = 0;
    }

    // Generate markers
    Map<String?, Marker> generatedMarkers = <String?, Marker>{};

    if (providers.isNotEmpty) {
      providers.forEach((element) {
        var marker1 = _generateMarkerForProvider(element);
        generatedMarkers[element.placeId] = marker1;
      });
    }
    this.markers = generatedMarkers;

    Future.delayed(Duration(milliseconds: 400), () {
      if (parentComponent == null) {
        return;
      }

      // Refresh parent component
      parentComponent!.refreshState();

      if (animateProviderToAPage) {
        parentComponent!.animateToPageIndex(_selectedPlaceIndex);
      }
    });
  }

  Marker _generateMarkerForProvider(GooglePlace provider) {
    return Marker(
      markerId: MarkerId(provider.placeId!),
      position: LatLng(provider.geometry!.location!.lat!, provider.geometry!.location!.lng!),
      icon: provider.placeId == _selectedPlaceId ? this.googleMapsHighlightedMarkerIcon : googleMapsMarkerIcon,
      consumeTapEvents: true,
      onTap: () {
        _selectedPlaceId = provider.placeId;
        generateMarkers(true);
      },
    );
  }
}
