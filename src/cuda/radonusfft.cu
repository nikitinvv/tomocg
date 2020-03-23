#include <stdio.h>

#include "radonusfft.cuh"
#include "kernels.cu"
#include "shift.cu"
#include <omp.h>

radonusfft::radonusfft(size_t ntheta, size_t pnz, size_t n, float center,
                       size_t theta_, size_t ngpus)
    : ntheta(ntheta), pnz(pnz), n(n), center(center), ngpus(ngpus) {
  float eps = 1e-3;
  mu = -log(eps) / (2 * n * n);
  m = ceil(2 * n * 1 / PI * sqrt(-mu * log(eps) + (mu * n) * (mu * n) / 4));
  f = new float2*[ngpus];
  g = new float2*[ngpus];
  fde = new float2*[ngpus];
  fdee = new float2*[ngpus];
  x = new float*[ngpus];
  y = new float*[ngpus];
  shiftfwd = new float2*[ngpus];
  shiftadj = new float2*[ngpus];
  theta = new float*[ngpus];
  plan1d = new cufftHandle[ngpus];  
  plan2dfwd = new cufftHandle[ngpus];
  plan2dadj = new cufftHandle[ngpus];
  omp_set_num_threads(ngpus);

  for (int igpu=0;igpu<ngpus;igpu++)
  {
    cudaSetDevice(igpu);
    cudaMalloc((void **)&f[igpu], n * n * pnz * sizeof(float2));
    cudaMalloc((void **)&g[igpu], n * ntheta * pnz * sizeof(float2));
    cudaMalloc((void **)&fde[igpu], 2 * n * 2 * n * pnz * sizeof(float2));
    cudaMalloc((void **)&fdee[igpu],
              (2 * n + 2 * m) * (2 * n + 2 * m) * pnz * sizeof(float2));

    cudaMalloc((void **)&x[igpu], n * ntheta * sizeof(float));
    cudaMalloc((void **)&y[igpu], n * ntheta * sizeof(float));
    cudaMalloc((void **)&theta[igpu], ntheta * sizeof(float));
    cudaMemcpy(theta[igpu], (float *)theta_, ntheta * sizeof(float), cudaMemcpyDefault);
    
    int ffts[2];
    int idist;
    int odist;
    int inembed[2];
    int onembed[2];
    // fft 2d
    ffts[0] = 2 * n;
    ffts[1] = 2 * n;
    idist = 2 * n * 2 * n;
    odist = (2 * n + 2 * m) * (2 * n + 2 * m);
    inembed[0] = 2 * n;
    inembed[1] = 2 * n;
    onembed[0] = 2 * n + 2 * m;
    onembed[1] = 2 * n + 2 * m;
    cufftPlanMany(&plan2dfwd[igpu], 2, ffts, inembed, 1, idist, onembed, 1, odist,
                  CUFFT_C2C, pnz);
    cufftPlanMany(&plan2dadj[igpu], 2, ffts, onembed, 1, odist, inembed, 1, idist,
                  CUFFT_C2C, pnz);
    
    // fft 1d
    ffts[0] = n;
    idist = n;
    odist = n;
    inembed[0] = n;
    onembed[0] = n;
    cufftPlanMany(&plan1d[igpu], 1, ffts, inembed, 1, idist, onembed, 1, odist,
                  CUFFT_C2C, ntheta * pnz);
    cudaMalloc((void **)&shiftfwd[igpu], n * sizeof(float2));
    cudaMalloc((void **)&shiftadj[igpu], n * sizeof(float2));
    // compute shifts with respect to the rotation center
    takeshift <<<ceil(n / 1024.0), 1024>>> (shiftfwd[igpu], -(center - n / 2.0), n);
    takeshift <<<ceil(n / 1024.0), 1024>>> (shiftadj[igpu], (center - n / 2.0), n);
    
  }
  BS2d = dim3(32, 32);
  BS3d = dim3(32, 32, 1);

  GS2d0 = dim3(ceil(n / (float)BS2d.x), ceil(ntheta / (float)BS2d.y));
  GS3d0 = dim3(ceil(n / (float)BS3d.x), ceil(n / (float)BS3d.y),
              ceil(pnz / (float)BS3d.z));
  GS3d1 = dim3(ceil(2 * n / (float)BS3d.x), ceil(2 * n / (float)BS3d.y),
              ceil(pnz / (float)BS3d.z));
  GS3d2 = dim3(ceil((2 * n + 2 * m) / (float)BS3d.x),
              ceil((2 * n + 2 * m) / (float)BS3d.y), ceil(pnz / (float)BS3d.z));
  GS3d3 = dim3(ceil(n / (float)BS3d.x), ceil(ntheta / (float)BS3d.y),
              ceil(pnz / (float)BS3d.z));
  
}

// destructor, memory deallocation
radonusfft::~radonusfft() { free(); }

void radonusfft::free() {
  if (!is_free) {
    for(int igpu=0;igpu<ngpus;igpu++)
    {
      cudaSetDevice(igpu);
      cudaFree(f[igpu]);
      cudaFree(g[igpu]);
      cudaFree(fde[igpu]);
      cudaFree(fdee[igpu]);
      cudaFree(x[igpu]);
      cudaFree(y[igpu]);
      cudaFree(shiftfwd[igpu]);
      cudaFree(shiftadj[igpu]);
      cufftDestroy(plan2dfwd[igpu]);
      cufftDestroy(plan2dadj[igpu]);
      cufftDestroy(plan1d[igpu]);
    }
    cudaFree(f);
    cudaFree(g);
    cudaFree(fde);
    cudaFree(fdee);
    cudaFree(x);
    cudaFree(y);
    cudaFree(shiftfwd);
    cudaFree(shiftadj);
  }
}

void radonusfft::fwd(size_t g_, size_t f_) {
  #pragma omp parallel for
  for(int igpu=0;igpu<ngpus;igpu++)
  {
    cudaSetDevice(igpu);
    float2* f0 = (float2 *)f_;
    cudaMemcpy(f[igpu], &f0[igpu*pnz*n*n], n * n * pnz * sizeof(float2), cudaMemcpyDefault);      
    cudaMemset(fde[igpu], 0, 2 * n * 2 * n * pnz * sizeof(float2));
    cudaMemset(fdee[igpu], 0, (2 * n + 2 * m) * (2 * n + 2 * m) * pnz * sizeof(float2));

    //circ <<<GS3d0, BS3d>>> (f, 1.0f / n, n, pnz);
    takexy <<<GS2d0, BS2d>>> (x[igpu], y[igpu], theta[igpu], n, ntheta);

    divphi <<<GS3d0, BS3d>>> (fde[igpu], f[igpu], mu, n, pnz, TOMO_FWD);
    fftshiftc <<<GS3d1, BS3d>>> (fde[igpu], 2 * n, pnz);
    cufftExecC2C(plan2dfwd[igpu], (cufftComplex *)fde[igpu],
                (cufftComplex *)&fdee[igpu][m + m * (2 * n + 2 * m)], CUFFT_FORWARD);
    fftshiftc <<<GS3d2, BS3d>>> (fdee[igpu], 2 * n + 2 * m, pnz);

    wrap <<<GS3d2, BS3d>>> (fdee[igpu], n, pnz, m, TOMO_FWD);
    gather <<<GS3d3, BS3d>>> (g[igpu], fdee[igpu], x[igpu], y[igpu], m, mu, n, ntheta, pnz, TOMO_FWD);
    // shift with respect to given center
    shift <<<GS3d3, BS3d>>> (g[igpu], shiftfwd[igpu], n, ntheta, pnz);

    ifftshiftc <<<GS3d3, BS3d>>> (g[igpu], n, ntheta, pnz);
    cufftExecC2C(plan1d[igpu], (cufftComplex *)g[igpu], (cufftComplex *)g[igpu], CUFFT_INVERSE);
    ifftshiftc <<<GS3d3, BS3d>>> (g[igpu], n, ntheta, pnz);

    float2* g0 = (float2 *)g_;
    for (int i=0;i<ntheta;i++)    
      cudaMemcpy(&g0[i*n*ngpus*pnz+igpu*pnz*n], &g[igpu][i*n*pnz], n * pnz * sizeof(float2), cudaMemcpyDefault);
  }
}

void radonusfft::adj(size_t f_, size_t g_) {
  #pragma omp parallel for
  for(int igpu=0;igpu<ngpus;igpu++)
  {    
    cudaSetDevice(igpu);
    float2* g0 = (float2 *)g_;
    for (int i=0;i<ntheta;i++)    
      cudaMemcpy(&g[igpu][i*n*pnz],&g0[i*n*ngpus*pnz+igpu*pnz*n], n * pnz * sizeof(float2), cudaMemcpyDefault);
    cudaMemset(fde[igpu], 0, (2 * n + 2 * m) * (2 * n + 2 * m) * pnz * sizeof(float2));
    cudaMemset(fdee[igpu], 0, (2 * n + 2 * m) * (2 * n + 2 * m) * pnz * sizeof(float2));

    takexy <<<GS2d0, BS2d>>> (x[igpu], y[igpu], theta[igpu], n, ntheta);

    ifftshiftc <<<GS3d3, BS3d>>> (g[igpu], n, ntheta, pnz);
    cufftExecC2C(plan1d[igpu], (cufftComplex *)g[igpu], (cufftComplex *)g[igpu], CUFFT_FORWARD);
    ifftshiftc <<<GS3d3, BS3d>>> (g[igpu], n, ntheta, pnz);
    // applyfilter<<<GS3d3, BS3d>>>(g,n,ntheta,pnz);
    // shift with respect to given center
    shift <<<GS3d3, BS3d>>> (g[igpu], shiftadj[igpu], n, ntheta, pnz);

    gather <<<GS3d3, BS3d>>> (g[igpu], fdee[igpu], x[igpu], y[igpu], m, mu, n, ntheta, pnz, TOMO_ADJ);
    wrap <<<GS3d2, BS3d>>> (fdee[igpu], n, pnz, m, TOMO_ADJ);

    fftshiftc <<<GS3d2, BS3d>>> (fdee[igpu], 2 * n + 2 * m, pnz);
    cufftExecC2C(plan2dadj[igpu], (cufftComplex *)&fdee[igpu][m + m * (2 * n + 2 * m)],
                (cufftComplex *)fde[igpu], CUFFT_INVERSE);
    fftshiftc <<<GS3d1, BS3d>>> (fde[igpu], 2 * n, pnz);

    divphi <<<GS3d0, BS3d>>> (fde[igpu], f[igpu], mu, n, pnz, TOMO_ADJ);
    //circ <<<GS3d0, BS3d>>> (f, 1.0f / n, n, pnz);
    float2* f0 = (float2 *)f_;
    cudaMemcpy(&f0[igpu*n*n*pnz], f[igpu], n * n * pnz * sizeof(float2),
              cudaMemcpyDefault);
  }
}
