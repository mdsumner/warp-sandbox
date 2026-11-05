// gdal-direct: GDAL's warp API with no utility layer.
//
//   GDALCreateGenImgProjTransformer2 (source dataset -> destination SRS),
//   GDALSetGenImgProjTransformerDstGeoTransform (the destination grid),
//   GDALCreateApproxTransformer (max_error, gdalwarp's -et),
//   GDALWarpOptions, GDALWarpOperation::ChunkAndWarpImage into a MEM dataset,
//   then one RasterIO per band into R.
//
// Compiled on first use by warpsandbox (Rcpp::sourceCpp, cached). A prototype
// for a GDAL7 binding.

#include <Rcpp.h>
#include "gdal_priv.h"
#include "gdal_alg.h"
#include "gdalwarper.h"
#include "cpl_string.h"

using namespace Rcpp;

// gdalwarp's -r names (GDALGetWarpResampleAlg is internal to the utility)
static GDALResampleAlg resample_alg(const std::string &r)
{
    if (r == "near") return GRA_NearestNeighbour;
    if (r == "bilinear") return GRA_Bilinear;
    if (r == "cubic") return GRA_Cubic;
    if (r == "cubicspline") return GRA_CubicSpline;
    if (r == "lanczos") return GRA_Lanczos;
    if (r == "average") return GRA_Average;
    if (r == "rms") return GRA_RMS;
    if (r == "mode") return GRA_Mode;
    if (r == "max") return GRA_Max;
    if (r == "min") return GRA_Min;
    if (r == "med") return GRA_Med;
    if (r == "q1") return GRA_Q1;
    if (r == "q3") return GRA_Q3;
    if (r == "sum") return GRA_Sum;
    Rcpp::stop("unknown resampling method: " + r);
}

// [[Rcpp::export]]
List gdal_direct_warp(std::string dsn, CharacterVector open_options, IntegerVector bands,
                      std::string dst_wkt, NumericVector dst_gt, IntegerVector dim,
                      std::string resample, std::string type, double max_error,
                      int alpha_band)
{
    GDALAllRegister();
    CPLStringList oo;
    for (R_xlen_t i = 0; i < open_options.size(); ++i)
        oo.AddString(Rcpp::as<std::string>(open_options[i]).c_str());

    GDALDatasetH hSrc = GDALOpenEx(dsn.c_str(), GDAL_OF_RASTER | GDAL_OF_READONLY,
                                   nullptr, oo.List(), nullptr);
    if (!hSrc) Rcpp::stop("could not open source: " + std::string(CPLGetLastErrorMsg()));

    const int nx = dim[0], ny = dim[1], nb = bands.size();

    // transformer: source pixel/line <-> destination pixel/line
    CPLStringList to;
    to.SetNameValue("DST_SRS", dst_wkt.c_str());
    void *hGenImg = GDALCreateGenImgProjTransformer2(hSrc, nullptr, to.List());
    if (!hGenImg) { GDALClose(hSrc); Rcpp::stop("transformer: " + std::string(CPLGetLastErrorMsg())); }
    double gt[6];
    for (int i = 0; i < 6; ++i) gt[i] = dst_gt[i];
    GDALSetGenImgProjTransformerDstGeoTransform(hGenImg, gt);
    void *hApprox = GDALCreateApproxTransformer(GDALGenImgProjTransform, hGenImg, max_error);
    GDALApproxTransformerOwnsSubtransformer(hApprox, TRUE);

    // destination: a MEM dataset of the source's data type, as gdalwarp makes
    GDALDataType eType = GDALGetRasterDataType(GDALGetRasterBand(hSrc, bands[0]));
    GDALDriverH hMem = GDALGetDriverByName("MEM");
    GDALDatasetH hDst = GDALCreate(hMem, "", nx, ny, nb, eType, nullptr);
    GDALSetGeoTransform(hDst, gt);
    GDALSetProjection(hDst, dst_wkt.c_str());

    GDALWarpOptions *wo = GDALCreateWarpOptions();
    wo->hSrcDS = hSrc;
    wo->hDstDS = hDst;
    wo->eResampleAlg = resample_alg(resample);
    wo->pfnTransformer = GDALApproxTransform;
    wo->pTransformerArg = hApprox;
    wo->nBandCount = nb;
    wo->panSrcBands = static_cast<int *>(CPLMalloc(sizeof(int) * nb));
    wo->panDstBands = static_cast<int *>(CPLMalloc(sizeof(int) * nb));
    bool any_nodata = false;
    std::vector<double> nodata(nb, 0.0);
    std::vector<int> has_nd(nb, 0);
    for (int i = 0; i < nb; ++i)
    {
        wo->panSrcBands[i] = bands[i];
        wo->panDstBands[i] = i + 1;
        nodata[i] = GDALGetRasterNoDataValue(GDALGetRasterBand(hSrc, bands[i]), &has_nd[i]);
        any_nodata = any_nodata || has_nd[i];
    }
    if (any_nodata)
    {
        // as gdalwarp: source nodata, copied to the destination
        wo->padfSrcNoDataReal = static_cast<double *>(CPLMalloc(sizeof(double) * nb));
        wo->padfDstNoDataReal = static_cast<double *>(CPLMalloc(sizeof(double) * nb));
        for (int i = 0; i < nb; ++i)
        {
            wo->padfSrcNoDataReal[i] = has_nd[i] ? nodata[i] : -1.1e20;
            wo->padfDstNoDataReal[i] = wo->padfSrcNoDataReal[i];
            if (has_nd[i]) GDALSetRasterNoDataValue(GDALGetRasterBand(hDst, i + 1), nodata[i]);
        }
        wo->papszWarpOptions = CSLSetNameValue(wo->papszWarpOptions, "INIT_DEST", "NO_DATA");
    }
    else
    {
        wo->papszWarpOptions = CSLSetNameValue(wo->papszWarpOptions, "INIT_DEST", "0");
    }
    // an alpha band among the requested ones masks the source (gdalwarp's
    // -srcalpha, which it detects itself); it is warped as data too
    if (alpha_band > 0) wo->nSrcAlphaBand = bands[alpha_band - 1];

    GDALWarpOperation op;
    CPLErr err = op.Initialize(wo);
    if (err == CE_None) err = op.ChunkAndWarpImage(0, 0, nx, ny);

    std::string msg = err == CE_None ? "" : CPLGetLastErrorMsg();
    List out(nb);
    if (err == CE_None)
    {
        for (int i = 0; i < nb; ++i)
        {
            GDALRasterBandH hb = GDALGetRasterBand(hDst, i + 1);
            // one RasterIO per band, straight into an R vector, row-major
            if (type == "raw")
            {
                RawVector v(static_cast<R_xlen_t>(nx) * ny);
                err = GDALRasterIO(hb, GF_Read, 0, 0, nx, ny, RAW(v), nx, ny, GDT_UInt8, 0, 0);
                out[i] = v;
            }
            else if (type == "integer")
            {
                IntegerVector v(static_cast<R_xlen_t>(nx) * ny);
                err = GDALRasterIO(hb, GF_Read, 0, 0, nx, ny, INTEGER(v), nx, ny, GDT_Int32, 0, 0);
                out[i] = v;
            }
            else
            {
                NumericVector v(static_cast<R_xlen_t>(nx) * ny);
                err = GDALRasterIO(hb, GF_Read, 0, 0, nx, ny, REAL(v), nx, ny, GDT_Float64, 0, 0);
                out[i] = v;
            }
            if (err != CE_None) { msg = CPLGetLastErrorMsg(); break; }
        }
    }

    GDALDestroyApproxTransformer(hApprox);
    wo->pTransformerArg = nullptr;
    wo->hSrcDS = nullptr;   // closed below
    wo->hDstDS = nullptr;
    GDALDestroyWarpOptions(wo);
    GDALClose(hDst);
    GDALClose(hSrc);
    if (!msg.empty()) Rcpp::stop("warp failed: " + msg);

    return List::create(_["bands"] = out,
                        _["nodata"] = any_nodata && has_nd[0] ? wrap(nodata[0]) : R_NilValue);
}
