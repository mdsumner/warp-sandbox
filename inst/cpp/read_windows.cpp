// Read several windows of a raster at once, on threads. Each window is split
// at the band's block-row boundaries, so every row of tiles is its own task,
// and the tasks run on up to `threads` threads, each with its own dataset
// handle (a GDALDataset is not thread-safe; GDAL's /vsicurl/ cache, shared
// by all handles in the process, is). Over HTTP the requests then overlap:
// about two round trips (the tile index, then the tiles) instead of one per
// tile row per window.
//
// Returns a list with one double vector per window: xsize * ysize values per
// band, row-major, bands one after another (as rwarp's read_fn returns),
// nodata as NaN only if GDAL gives NaN (the caller maps nodata).
#include <Rcpp.h>
#include <gdal.h>
#include <cpl_conv.h>
#include <cpl_string.h>
#include <atomic>
#include <thread>
#include <vector>
#include <string>
#include <mutex>

// [[Rcpp::export]]
Rcpp::List gdal_read_windows(std::string dsn, Rcpp::CharacterVector open_options,
                             Rcpp::IntegerMatrix windows, Rcpp::IntegerVector bands,
                             int threads) {
  GDALAllRegister();
  const int nw = windows.nrow();
  const int nb = bands.size();
  std::vector<std::string> oo_s;
  for (R_xlen_t i = 0; i < open_options.size(); i++) oo_s.push_back(Rcpp::as<std::string>(open_options[i]));
  auto open = [&]() -> GDALDatasetH {
    std::vector<const char*> oo;
    for (auto& s : oo_s) oo.push_back(s.c_str());
    oo.push_back(nullptr);
    return GDALOpenEx(dsn.c_str(), GDAL_OF_RASTER | GDAL_OF_READONLY, nullptr, oo.data(), nullptr);
  };
  // block height from a handle opened here (the header is in the cache by now)
  GDALDatasetH ds0 = open();
  if (ds0 == nullptr) Rcpp::stop("could not open %s", dsn);
  int bx = 0, by = 0;
  GDALGetBlockSize(GDALGetRasterBand(ds0, bands[0]), &bx, &by);
  GDALClose(ds0);
  if (by < 1) by = 256;

  struct Task { int w, y0, y1; };
  std::vector<Task> tasks;
  std::vector<std::vector<double>> out(nw);
  for (int i = 0; i < nw; i++) {
    const int xs = windows(i, 2), ys = windows(i, 3), yo = windows(i, 1);
    out[i].assign((size_t)xs * ys * nb, NA_REAL);
    if (xs < 1 || ys < 1) continue;
    int y = yo;
    while (y < yo + ys) {
      const int next = std::min(yo + ys, (y / by + 1) * by);
      tasks.push_back({i, y, next});
      y = next;
    }
  }
  std::vector<int> band_list(bands.begin(), bands.end());
  std::atomic<size_t> next_task(0);
  std::mutex err_mu;
  std::string err;
  auto worker = [&]() {
    GDALDatasetH ds = open();
    if (ds == nullptr) { std::lock_guard<std::mutex> l(err_mu); err = "could not open " + dsn; return; }
    for (size_t k = next_task++; k < tasks.size(); k = next_task++) {
      const Task& t = tasks[k];
      const int xo = windows(t.w, 0), xs = windows(t.w, 2), yo = windows(t.w, 1), ys = windows(t.w, 3);
      const int rows = t.y1 - t.y0;
      // band-sequential, row-major: band b's rows start at b * xs * ys
      double* dst = out[t.w].data() + (size_t)(t.y0 - yo) * xs;
      CPLErr e = GDALDatasetRasterIO(ds, GF_Read, xo, t.y0, xs, rows, dst, xs, rows, GDT_Float64,
                                     nb, band_list.data(), sizeof(double), (GSpacing)xs * sizeof(double),
                                     (GSpacing)xs * ys * sizeof(double));
      if (e != CE_None) { std::lock_guard<std::mutex> l(err_mu); err = CPLGetLastErrorMsg(); }
    }
    GDALClose(ds);
  };
  const int nt = std::max(1, std::min<int>(threads, (int)tasks.size()));
  std::vector<std::thread> pool;
  for (int i = 0; i < nt; i++) pool.emplace_back(worker);
  for (auto& th : pool) th.join();
  if (!err.empty()) Rcpp::stop("read failed: %s", err);
  Rcpp::List res(nw);
  for (int i = 0; i < nw; i++) res[i] = Rcpp::wrap(out[i]);
  return res;
}
