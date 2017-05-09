// @file nnroipooling.cu
// @brief roipooling block
// @author Hakan Bilen
// @author Abishek Dutta
// @author Andrea Vedaldi

/*
Copyright (C) 2016 Hakan Bilen, Abishek Dutta, and Andrea Vedaldi.
All rights reserved.

This file is part of the VLFeat library and is made available under
the terms of the BSD license (see the COPYING file).
*/

#include "nnroipooling.hpp"
#include "impl/dispatcher.hpp"
#include <cassert>
#include <cmath>
#include <iostream>

using namespace std ;
using namespace vl ;
using namespace vl::nn ;

template<DeviceType deviceType, DataType dataType> struct ROIPoolingMaxForward ;
template<DeviceType deviceType, DataType dataType> struct ROIPoolingMaxBackward ;
template<DeviceType deviceType, DataType dataType> struct ROIPoolingMeanForward ;
template<DeviceType deviceType, DataType dataType> struct ROIPoolingMeanBackward ;

// -------------------------------------------------------------------
//                                                             Helpers
// -------------------------------------------------------------------

template <typename type>
struct acc_max
{
  inline acc_max(int poolHeight, int poolWidth, type derOutput = 0)
  :
  value(-std::numeric_limits<type>::infinity()),
  derOutput(derOutput),
  derDataActivePt(NULL)
  { }

  inline void accumulate_forward(type x) {
    value = std::max(value, x) ;
  }

  inline void accumulate_backward(type const* data, type* derDataPt) {
    type x = *data ;
    if (x > value) {
      value = x ;
      derDataActivePt = derDataPt ;
    }
  }

  inline type done_forward() const {
    return value ;
  }

  inline void done_backward() const {
    if (derDataActivePt) { *derDataActivePt += derOutput ; }
  }

  type value ;
  type derOutput ;
  type* derDataActivePt ;
} ;

template <typename type>
struct acc_sum
{
  inline acc_sum(int poolHeight, int poolWidth, type derOutput = 0)
  :
  value(0),
  scale(type(1)/type(poolHeight*poolWidth)),
  derOutput(derOutput)
  { }

  inline void accumulate_forward(type x) {
    value += x ;
  }

  inline void accumulate_backward(type const* data, type* derDataPt) {
    *derDataPt += derOutput * scale ;
  }

  inline type done_forward() const {
    return value * scale ;
  }

  inline void done_backward() const { }

  type value ;
  type derOutput ;
  type scale;
} ;

template<DeviceType deviceType, DataType dataType> struct ROIPoolingMaxForward ;
template<DeviceType deviceType, DataType dataType> struct ROIPoolingMaxBackward ;
template<DeviceType deviceType, DataType dataType> struct ROIPoolingAverageForward ;
template<DeviceType deviceType, DataType dataType> struct ROIPoolingAverageBackward ;

// -------------------------------------------------------------------
//                                                             Forward
// -------------------------------------------------------------------

template<DataType dataType, class Accumulator>
struct ROIPoolingForward
{
  vl::ErrorCode operator()(ROIPooling &op,
                           Tensor pooled,
                           Tensor input,
                           Tensor rois)
  {
    typedef typename vl::DataTypeTraits<dataType>::type type ;
    auto numROIs = rois.getNumElements() / 5 ;
    auto height = input.getHeight() ;
    auto width = input.getWidth() ;
    auto depth = input.getDepth() ;
    auto size = input.getSize() ;
    auto roisData = (type const*)rois.getMemory() ;
    auto inputData = (type const*)input.getMemory() ;
    auto pooledData = (type*)pooled.getMemory() ;

    // For each ROI R = [t x1 y1 x2 y2].
    for (int roi = 0; roi < numROIs; ++roi) {

      // Apply scale and offset to each ROI coordinate.
      type u1_ = roisData[5 * roi + 1] ;
      type v1_ = roisData[5 * roi + 2] ;
      type u2_ = roisData[5 * roi + 3] ;
      type v2_ = roisData[5 * roi + 4] ;

      type u1 = op.transform[0] * u1_ + op.transform[2] * v1_ + op.transform[4] ;
      type v1 = op.transform[1] * u1_ + op.transform[3] * v1_ + op.transform[5] ;
      type u2 = op.transform[0] * u2_ + op.transform[2] * v2_ + op.transform[4] ;
      type v2 = op.transform[1] * u2_ + op.transform[3] * v2_ + op.transform[5] ;

      // First and last pixel of each ROI (rounded
      // for compatibility with the Caffe definition).
      int roi_image   = (int)roisData[5 * roi + 0];
      int roi_start_h = (int)::round(v1) - 1 ;
      int roi_start_w = (int)::round(u1) - 1 ;
      int roi_end_h   = (int)::round(v2) - 1 ;
      int roi_end_w   = (int)::round(u2) - 1 ;
      int roi_height  = max(roi_end_h - roi_start_h + 1, 1) ;
      int roi_width   = max(roi_end_w - roi_start_w + 1, 1) ;

      roi_image = min(max(roi_image - 1,0), (int)size - 1) ;
      type const * data_offset = inputData + (roi_image * depth) * (width*height) ;

      type bin_size_h = (type)roi_height / op.subdivisions[0] ;
      type bin_size_w = (type)roi_width / op.subdivisions[1] ;

      // For each feature channel.
      for (int z = 0; z < depth; ++z) {

        // For each column of tiles.
        for (int pw = 0; pw < op.subdivisions[1]; ++pw) {
          int wstart = (int)floor(((type)pw) * bin_size_w) ;
          int wend = (int)ceil(((type)(pw + 1)) * bin_size_w) ;
          wstart = min(max(wstart + roi_start_w, 0), (int)width) ;
          wend = min(max(wend + roi_start_w, 0), (int)width) ;

          // For each tile in a column.
          for (int ph = 0; ph < op.subdivisions[0]; ++ph) {
            int hstart = (int)floor(((type)ph) * bin_size_h) ;
            int hend = (int)ceil(((type)(ph + 1)) * bin_size_h) ;
            hstart = min(max(hstart + roi_start_h, 0), (int)height) ;
            hend = min(max(hend + roi_start_h, 0), (int)height) ;

            bool is_empty = (hend <= hstart) || (wend <= wstart);

            if (is_empty) {
              *pooledData++ = 0 ;
            }
            else {
              Accumulator acc(hend - hstart, wend - wstart) ;
              for (int w = wstart ; w < wend; ++w) {
                for (int h = hstart ; h < hend; ++h) {
                  const int index = w * height + h ;
                  acc.accumulate_forward(data_offset[index]) ;
                }
              }
              *pooledData++ = acc.done_forward() ;
            }
          } // end of ph
        } // end of pw
        data_offset += width*height;
      } // end of z
    } // end of n
    return VLE_Success ;
  }
} ;

template<DataType dataType>
struct ROIPoolingMaxForward<VLDT_CPU,dataType> :
public ROIPoolingForward<dataType,acc_max<typename vl::DataTypeTraits<dataType>::type> >
{ } ;

template<DataType dataType>
struct ROIPoolingAverageForward<VLDT_CPU,dataType> :
public ROIPoolingForward<dataType,acc_max<typename vl::DataTypeTraits<dataType>::type> >
{ } ;

template<DataType dataType, class Accumulator>
struct ROIPoolingBackward
{
  vl::ErrorCode operator()(ROIPooling &op,
                           Tensor derInput,
                           Tensor input,
                           Tensor rois,
                           Tensor derOutput)
  {
    typedef typename vl::DataTypeTraits<dataType>::type type ;
    auto numROIs = rois.getNumElements() / 5 ;
    auto height = input.getHeight() ;
    auto width = input.getWidth() ;
    auto depth = input.getDepth() ;
    auto size = input.getSize() ;
    auto derInputData = (type*)derInput.getMemory() ;
    auto roisData = (type const*)rois.getMemory() ;
    auto inputData = (type const*)input.getMemory() ;
    auto derOutputData = (type const*)derOutput.getMemory() ;

    // For each ROI R = [t x1 y1 x2 y2].
    for (size_t roi = 0; roi < numROIs ; ++roi) {

      // Apply sacle and offset to each ROI coordinate.
      type u1_ = roisData[5 * roi + 1] ;
      type v1_ = roisData[5 * roi + 2] ;
      type u2_ = roisData[5 * roi + 3] ;
      type v2_ = roisData[5 * roi + 4] ;

      type u1 = op.transform[0] * u1_ + op.transform[2] * v1_ + op.transform[4] ;
      type v1 = op.transform[1] * u1_ + op.transform[3] * v1_ + op.transform[5] ;
      type u2 = op.transform[0] * u2_ + op.transform[2] * v2_ + op.transform[4] ;
      type v2 = op.transform[1] * u2_ + op.transform[3] * v2_ + op.transform[5] ;

      // First and last pixel of each ROI (rounded
      // for compatibility with the Caffe definition).
      int roi_image   = (int)roisData[5 * roi + 0];
      int roi_start_h = (int)::round(v1) - 1 ;
      int roi_start_w = (int)::round(u1) - 1 ;
      int roi_end_h   = (int)::round(v2) - 1 ;
      int roi_end_w   = (int)::round(u2) - 1 ;
      int roi_height = max(roi_end_h - roi_start_h + 1, 1) ;
      int roi_width = max(roi_end_w - roi_start_w + 1, 1) ;

      roi_image = min(max(roi_image - 1,0), (int)size - 1) ;
      type const * data_offset = inputData + (roi_image * depth) * (width*height);
      type * derData_offset = derInputData + (roi_image * depth) * (width*height);

      const type bin_size_h = (double)roi_height / op.subdivisions[0] ;
      const type bin_size_w = (double)roi_width / op.subdivisions[1] ;

      // For each feature channel.
      for (int z = 0; z < depth; ++z) {

        // For each column of tiles.
        for (int pw = 0; pw < op.subdivisions[1]; ++pw) {
          int wstart = (int)floor(((type)pw) * bin_size_w) ;
          int wend = (int)ceil(((type)(pw + 1)) * bin_size_w) ;
          wstart = min(max(wstart + roi_start_w, 0), (int)width) ;
          wend = min(max(wend + roi_start_w, 0), (int)width) ;

          // For each tile in a column.
          for (int ph = 0; ph < op.subdivisions[0]; ++ph) {
            int hstart = (int)floor(((type)ph) * bin_size_h) ;
            int hend = (int)ceil(((type)(ph + 1)) * bin_size_h) ;
            hstart = min(max(hstart + roi_start_h, 0), (int)height) ;
            hend = min(max(hend + roi_start_h, 0), (int)height) ;

            Accumulator acc(hend - hstart, wend - wstart, *derOutputData++) ;
            for (int w = wstart; w < wend; ++w) {
              for (int h = hstart; h < hend; ++h) {
                const int index = w * height + h ;
                acc.accumulate_backward(&data_offset[index],
                                        &derData_offset[index]) ;
              }
            }
            acc.done_backward() ;
          } // end of pw
        } // end of ph
        data_offset += width*height ;
        derData_offset += width*height ;
      } // end of z
    } // end of n

    return VLE_Success ;
  }
} ;

template<DataType dataType>
struct ROIPoolingMaxBackward<VLDT_CPU,dataType> :
public ROIPoolingBackward<dataType,acc_max<typename vl::DataTypeTraits<dataType>::type> >
{ } ;

template<DataType dataType>
struct ROIPoolingAverageBackward<VLDT_CPU,dataType> :
public ROIPoolingBackward<dataType,acc_max<typename vl::DataTypeTraits<dataType>::type> >
{ } ;

// -------------------------------------------------------------------
//                                                              Driver
// -------------------------------------------------------------------

#if ENABLE_GPU
#include "nnroipooling_gpu.cu"
#endif

ROIPooling::ROIPooling(Context &context,
                       array<int,2> subdivisions,
                       array<double,6> transform,
                       Method method) :
context(context),
subdivisions(subdivisions),
transform(transform),
method(method)
{ }

vl::ErrorCode
ROIPooling::forward(vl::Tensor output,
                    vl::Tensor input,
                    vl::Tensor rois)
{
  switch (method) {
    case Max: return dispatch<ROIPoolingMaxForward>()(*this,output,input,rois) ;
    case Average: return dispatch<ROIPoolingAverageForward>()(*this,output,input,rois) ;
    default: return VLE_IllegalArgument ;
  }
}

vl::ErrorCode
ROIPooling::backward(vl::Tensor derInput,
                     vl::Tensor input,
                     vl::Tensor rois,
                     vl::Tensor derOutput)
{
  switch (method) {
    case Max: return dispatch<ROIPoolingMaxBackward>()(*this,derInput,input,rois,derOutput) ;
    case Average: return dispatch<ROIPoolingAverageBackward>()(*this,derInput,input,rois,derOutput) ;
    default: return VLE_IllegalArgument ;
  }
}
