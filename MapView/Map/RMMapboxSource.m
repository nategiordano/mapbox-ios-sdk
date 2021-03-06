//
//  RMMapboxSource.m
//
//  Created by Justin R. Miller on 5/17/11.
//  Copyright 2012-2013 Mapbox.
//  All rights reserved.
//  
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//  
//      * Redistributions of source code must retain the above copyright
//        notice, this list of conditions and the following disclaimer.
//  
//      * Redistributions in binary form must reproduce the above copyright
//        notice, this list of conditions and the following disclaimer in the
//        documentation and/or other materials provided with the distribution.
//  
//      * Neither the name of Mapbox, nor the names of its contributors may be
//        used to endorse or promote products derived from this software
//        without specific prior written permission.
//  
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

#import "RMMapboxSource.h"

#import "RMMapView.h"
#import "RMPointAnnotation.h"
#import "RMConfiguration.h"

@interface RMMapboxSource ()

@property (nonatomic, strong) NSDictionary *infoDictionary;
@property (nonatomic, strong) NSString *tileJSON;
@property (nonatomic, strong) NSString *uniqueTilecacheKey;

@end

#pragma mark -

@implementation RMMapboxSource

@synthesize infoDictionary=_infoDictionary, tileJSON=_tileJSON, imageQuality=_imageQuality, dataQueue=_dataQueue, uniqueTilecacheKey=_uniqueTilecacheKey;

- (id)init
{
    return [self initWithReferenceURL:[NSURL fileURLWithPath:[RMMapView pathForBundleResourceNamed:kMapboxPlaceholderMapID ofType:@"json"]]];
}

- (id)initWithMapID:(NSString *)mapID
{
    return [self initWithMapID:mapID enablingSSL:NO];
}

- (id)initWithMapID:(NSString *)mapID enablingSSL:(BOOL)enableSSL
{
    return [self initWithMapID:mapID enablingDataOnMapView:nil enablingSSL:enableSSL];
}

- (id)initWithTileJSON:(NSString *)tileJSON
{
    return [self initWithTileJSON:tileJSON enablingDataOnMapView:nil];
}

- (id)initWithTileJSON:(NSString *)tileJSON enablingDataOnMapView:(RMMapView *)mapView
{
    if (self = [super init])
    {
        _dataQueue = dispatch_queue_create(nil, DISPATCH_QUEUE_SERIAL);

        _infoDictionary = (NSDictionary *)[NSJSONSerialization JSONObjectWithData:[tileJSON dataUsingEncoding:NSUTF8StringEncoding]
                                                                          options:0
                                                                            error:nil];
        if ( ! _infoDictionary)
            return nil;

        _tileJSON = tileJSON;

        _uniqueTilecacheKey = [NSString stringWithFormat:@"Mapbox-%@%@", [_infoDictionary objectForKey:@"id"], ([_infoDictionary objectForKey:@"version"] ? [@"-" stringByAppendingString:[_infoDictionary objectForKey:@"version"]] : @"")];

        id dataObject = nil;
        
        if (mapView && (dataObject = [_infoDictionary objectForKey:@"data"]) && dataObject)
        {
            dispatch_async(_dataQueue, ^(void)
            {
                if ([dataObject isKindOfClass:[NSArray class]] && [[dataObject objectAtIndex:0] isKindOfClass:[NSString class]])
                {
                    NSURL *dataURL = [NSURL URLWithString:[dataObject objectAtIndex:0]];
                    
                    NSMutableString *jsonString = nil;
                    
                    if (dataURL && (jsonString = [NSMutableString brandedStringWithContentsOfURL:dataURL encoding:NSUTF8StringEncoding error:nil]) && jsonString)
                    {
                        if ([jsonString hasPrefix:@"grid("])
                        {
                            [jsonString replaceCharactersInRange:NSMakeRange(0, 5)                       withString:@""];
                            [jsonString replaceCharactersInRange:NSMakeRange([jsonString length] - 2, 2) withString:@""];
                        }
                        
                        id jsonObject = nil;
                        
                        if ((jsonObject = [NSJSONSerialization JSONObjectWithData:[jsonString dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]) && [jsonObject isKindOfClass:[NSDictionary class]])
                        {
                            for (NSDictionary *feature in [jsonObject objectForKey:@"features"])
                            {
                                NSDictionary *properties = [feature objectForKey:@"properties"];
                                
                                CLLocationCoordinate2D coordinate = {
                                    .longitude = [[[[feature objectForKey:@"geometry"] objectForKey:@"coordinates"] objectAtIndex:0] floatValue],
                                    .latitude  = [[[[feature objectForKey:@"geometry"] objectForKey:@"coordinates"] objectAtIndex:1] floatValue]
                                };

                                RMAnnotation *annotation = nil;

                                if ([mapView.delegate respondsToSelector:@selector(mapView:layerForAnnotation:)])
                                    annotation = [RMAnnotation annotationWithMapView:mapView coordinate:coordinate andTitle:[properties objectForKey:@"title"]];
                                else
                                    annotation = [RMPointAnnotation annotationWithMapView:mapView coordinate:coordinate andTitle:[properties objectForKey:@"title"]];
                                
                                annotation.userInfo = properties;
                                
                                dispatch_async(dispatch_get_main_queue(), ^(void)
                                {
                                    [mapView addAnnotation:annotation];
                                });
                            }
                        }
                    }
                }
            });            
        }
    }
    
    return self;
}

- (id)initWithReferenceURL:(NSURL *)referenceURL
{
    return [self initWithReferenceURL:referenceURL enablingDataOnMapView:nil];
}

- (id)initWithReferenceURL:(NSURL *)referenceURL enablingDataOnMapView:(RMMapView *)mapView
{
    id dataObject = nil;
    
    if ([[referenceURL pathExtension] isEqualToString:@"jsonp"])
        referenceURL = [NSURL URLWithString:[[referenceURL absoluteString] stringByReplacingOccurrencesOfString:@".jsonp" 
                                                                                                     withString:@".json"
                                                                                                        options:NSAnchoredSearch & NSBackwardsSearch
                                                                                                          range:NSMakeRange(0, [[referenceURL absoluteString] length])]];
    
    if ([[referenceURL pathExtension] isEqualToString:@"json"] && (dataObject = [NSString brandedStringWithContentsOfURL:referenceURL encoding:NSUTF8StringEncoding error:nil]) && dataObject)
        return [self initWithTileJSON:dataObject enablingDataOnMapView:mapView];
    
    // LeadNav customization to allow initialization without an internet connection
    if (!dataObject) {
        NSString *mapID = [referenceURL.absoluteString.lastPathComponent stringByDeletingPathExtension];
        NSMutableString *json = [NSMutableString stringWithString:@"{"];
        [json appendFormat:@"\"id\":\"%@\",", mapID];
        [json appendString:@"\"bounds\":[-180,-85,180,85],"];
        [json appendString:@"\"center\":[0,0,3],"];
        [json appendString:@"\"maxzoom\":19,"];
        [json appendString:@"\"minzoom\":0,"];
        [json appendString:@"\"scheme\":\"xyz\","];
        [json appendFormat:@"\"tiles\":[\"http://a.tiles.mapbox.com/v3/%@/{z}/{x}/{y}.png\",\"http://b.tiles.mapbox.com/v3/%@/{z}/{x}/{y}.png\"]", mapID, mapID];
        [json appendString:@"}"];
        
        dataObject = (NSString *)[json copy];
        
        return [self initWithTileJSON:dataObject enablingDataOnMapView:mapView];
    }

    return nil;
}

- (id)initWithMapID:(NSString *)mapID enablingDataOnMapView:(RMMapView *)mapView
{
    return [self initWithMapID:mapID enablingDataOnMapView:mapView enablingSSL:NO];
}

- (id)initWithMapID:(NSString *)mapID enablingDataOnMapView:(RMMapView *)mapView enablingSSL:(BOOL)enableSSL
{
    NSString *referenceURLString = [NSString stringWithFormat:@"http%@://api.tiles.mapbox.com/v3/%@.json%@", (enableSSL ? @"s" : @""), mapID, (enableSSL ? @"?secure" : @"")];

    /* map mapID -> LNMapSource */
    if ([mapID isEqualToString:@"leadnavsystems.ik5blff4"])
        self.LNMapSource = kMapSourceMapboxStreet;
    else if ([mapID isEqualToString:@"leadnavsystems.ik5afhmh"])
        self.LNMapSource = kMapSourceMapboxTerrain;
    else if ([mapID isEqualToString:@"leadnavsystems.ik210om1"])
        self.LNMapSource = kMapSourceMapboxSatellite;
    else
        self.LNMapSource = kMapSourceNone;

    return [self initWithReferenceURL:[NSURL URLWithString:referenceURLString] enablingDataOnMapView:mapView];
}

- (void)dealloc
{
#if ! OS_OBJECT_USE_OBJC
    if (_dataQueue)
        dispatch_release(_dataQueue);
#endif
}

#pragma mark 

- (NSURL *)tileJSONURL
{
    BOOL useSSL = [[[self.infoDictionary objectForKey:@"tiles"] objectAtIndex:0] hasPrefix:@"https"];

    return [NSURL URLWithString:[NSString stringWithFormat:@"http%@://api.tiles.mapbox.com/v3/%@.json%@", (useSSL ? @"s" : @""), [self.infoDictionary objectForKey:@"id"], (useSSL ? @"?secure" : @"")]];
}

- (NSURL *)URLForTile:(RMTile)tile
{
    NSInteger zoom = tile.zoom;
    NSInteger x    = tile.x;
    NSInteger y    = tile.y;

    if ([self.infoDictionary objectForKey:@"scheme"] && [[self.infoDictionary objectForKey:@"scheme"] isEqual:@"tms"])
        y = pow(2, zoom) - tile.y - 1;

    NSString *tileURLString = nil;

    if ([self.infoDictionary objectForKey:@"tiles"])
        tileURLString = [[self.infoDictionary objectForKey:@"tiles"] objectAtIndex:0];

    else
        tileURLString = [self.infoDictionary objectForKey:@"tileURL"];

    tileURLString = [tileURLString stringByReplacingOccurrencesOfString:@"{z}" withString:[[NSNumber numberWithInteger:zoom] stringValue]];
    tileURLString = [tileURLString stringByReplacingOccurrencesOfString:@"{x}" withString:[[NSNumber numberWithInteger:x]    stringValue]];
    tileURLString = [tileURLString stringByReplacingOccurrencesOfString:@"{y}" withString:[[NSNumber numberWithInteger:y]    stringValue]];

    if ([[UIScreen mainScreen] scale] > 1.0)
        tileURLString = [tileURLString stringByReplacingOccurrencesOfString:@".png" withString:@"@2x.png"];

    if (_imageQuality != RMMapboxSourceQualityFull)
    {
        NSString *qualityExtension = nil;

        switch (_imageQuality)
        {
            case RMMapboxSourceQualityPNG32:
            {
                qualityExtension = @".png32";
                break;
            }
            case RMMapboxSourceQualityPNG64:
            {
                qualityExtension = @".png64";
                break;
            }
            case RMMapboxSourceQualityPNG128:
            {
                qualityExtension = @".png128";
                break;
            }
            case RMMapboxSourceQualityPNG256:
            {
                qualityExtension = @".png256";
                break;
            }
            case RMMapboxSourceQualityJPEG70:
            {
                qualityExtension = @".jpg70";
                break;
            }
            case RMMapboxSourceQualityJPEG80:
            {
                qualityExtension = @".jpg80";
                break;
            }
            case RMMapboxSourceQualityJPEG90:
            {
                qualityExtension = @".jpg90";
                break;
            }
            case RMMapboxSourceQualityFull:
            default:
            {
                qualityExtension = @".png";
                break;
            }
        }

        tileURLString = [tileURLString stringByReplacingOccurrencesOfString:@".png"
                                                                 withString:qualityExtension
                                                                    options:NSAnchoredSearch | NSBackwardsSearch
                                                                      range:NSMakeRange(0, [tileURLString length])];
    }

	return [NSURL URLWithString:tileURLString];
}

- (float)minZoom
{
    return [[self.infoDictionary objectForKey:@"minzoom"] floatValue];
}

- (float)maxZoom
{
    return [[self.infoDictionary objectForKey:@"maxzoom"] floatValue];
}

- (RMSphericalTrapezium)latitudeLongitudeBoundingBox
{
    id bounds = [self.infoDictionary objectForKey:@"bounds"];

    NSArray *parts = nil;

    if ([bounds isKindOfClass:[NSArray class]])
        parts = bounds;

    else
        parts = [bounds componentsSeparatedByString:@","];

    if ([parts count] == 4)
    {
        RMSphericalTrapezium bounds = {
            .southWest = {
                .longitude = [[parts objectAtIndex:0] doubleValue],
                .latitude  = [[parts objectAtIndex:1] doubleValue],
            },
            .northEast = {
                .longitude = [[parts objectAtIndex:2] doubleValue],
                .latitude  = [[parts objectAtIndex:3] doubleValue],
            },
        };

        return bounds;
    }

    return kMapboxDefaultLatLonBoundingBox;
}

- (BOOL)coversFullWorld
{
    RMSphericalTrapezium ownBounds     = [self latitudeLongitudeBoundingBox];
    RMSphericalTrapezium defaultBounds = kMapboxDefaultLatLonBoundingBox;

    if (ownBounds.southWest.longitude <= defaultBounds.southWest.longitude + 10 && 
        ownBounds.northEast.longitude >= defaultBounds.northEast.longitude - 10)
        return YES;

    return NO;
}

- (NSString *)legend
{
    return [self.infoDictionary objectForKey:@"legend"];
}

- (CLLocationCoordinate2D)centerCoordinate
{
    if ([self.infoDictionary objectForKey:@"center"])
    {
        return CLLocationCoordinate2DMake([[[self.infoDictionary objectForKey:@"center"] objectAtIndex:1] doubleValue], 
                                          [[[self.infoDictionary objectForKey:@"center"] objectAtIndex:0] doubleValue]);
    }
    
    return CLLocationCoordinate2DMake(0, 0);
}

- (float)centerZoom
{
    if ([self.infoDictionary objectForKey:@"center"])
    {
        return [[[self.infoDictionary objectForKey:@"center"] objectAtIndex:2] floatValue];
    }
    
    return roundf(([self maxZoom] + [self minZoom]) / 2);
}

- (NSString *)uniqueTilecacheKey
{
    return _uniqueTilecacheKey;
}

- (NSString *)shortName
{
	return [self.infoDictionary objectForKey:@"name"];
}

- (NSString *)longDescription
{
	return [self.infoDictionary objectForKey:@"description"];
}

- (NSString *)shortAttribution
{
	return [self.infoDictionary objectForKey:@"attribution"];
}

- (NSString *)longAttribution
{
	return [self shortAttribution];
}

@end
