/*  linux_port.c

This file is part of a program that implements a Software-Defined Radio.

Copyright (C) 2013 Warren Pratt, NR0V and John Melton, G0ORX/N6LYT

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

The author can be reached by email at  

warren@wpratt.com
john.d.melton@googlemail.com

*/

#include "linux_port.h"
#include "comm.h"

/********************************************************************************************************
*													*
*	Linux Port Utilities										*
*													*
********************************************************************************************************/

#if defined(linux) || defined(__APPLE__)

void QueueUserWorkItem(void *function,void *context,int flags) {
	pthread_t t;
	pthread_create(&t, NULL, function, context);
	pthread_join(t, NULL);
}

void InitializeCriticalSectionAndSpinCount(pthread_mutex_t *mutex,int count) {
	pthread_mutexattr_t mAttr;
	pthread_mutexattr_init(&mAttr);
#ifdef __APPLE__
	// DL1YCF: MacOS X does not have PTHREAD_MUTEX_RECURSIVE_NP
	pthread_mutexattr_settype(&mAttr,PTHREAD_MUTEX_RECURSIVE);
	// macOS pthread mutexes default to the FIRSTFIT (unfair) policy: the channel's
	// DSP worker thread, re-acquiring csDSP in its block loop, can starve a control
	// setter (SetRXAAGCTop etc.) for hundreds of milliseconds — observed live as
	// audio dropouts on every slider move. FAIRSHARE hands the lock off FIFO, so a
	// setter waits at most one processing block.
	pthread_mutexattr_setpolicy_np(&mAttr, PTHREAD_MUTEX_POLICY_FAIRSHARE_NP);
#else
	pthread_mutexattr_settype(&mAttr,PTHREAD_MUTEX_RECURSIVE_NP);
#endif
	pthread_mutex_init(mutex,&mAttr);
	pthread_mutexattr_destroy(&mAttr);
	// ignore count
}

void InitializeCriticalSection(pthread_mutex_t *mutex) {
	InitializeCriticalSectionAndSpinCount(mutex, 0);
}

void EnterCriticalSection(pthread_mutex_t *mutex) {
	pthread_mutex_lock(mutex);
}

void LeaveCriticalSection(pthread_mutex_t *mutex) {
	pthread_mutex_unlock(mutex);
}

void DeleteCriticalSection(pthread_mutex_t *mutex) {
	pthread_mutex_destroy(mutex);
}

wdsp_sem_t *LinuxCreateSemaphore(int attributes,int initial_count,int maximum_count,char *name) {
	wdsp_sem_t *sem = malloc(sizeof(wdsp_sem_t));
	pthread_mutex_init(&sem->m, NULL);
	pthread_cond_init(&sem->c, NULL);
	sem->count = initial_count;
	return sem;
}

// Returns WAIT_OBJECT_0 (0) when the semaphore was acquired, WAIT_TIMEOUT otherwise.
int LinuxWaitForSingleObject(wdsp_sem_t *sem,int ms) {
	int acquired = 0;
	pthread_mutex_lock(&sem->m);
	if (ms == INFINITE) {
		while (sem->count <= 0)
			pthread_cond_wait(&sem->c, &sem->m);
		acquired = 1;
	} else if (ms == 0) {
		acquired = (sem->count > 0);
	} else {
		struct timespec deadline;
		clock_gettime(CLOCK_REALTIME, &deadline);
		deadline.tv_sec  += ms / 1000;
		deadline.tv_nsec += (long)(ms % 1000) * 1000000L;
		if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
		while (sem->count <= 0)
			if (pthread_cond_timedwait(&sem->c, &sem->m, &deadline) != 0) break;
		acquired = (sem->count > 0);
	}
	if (acquired) sem->count--;
	pthread_mutex_unlock(&sem->m);
	return acquired ? WAIT_OBJECT_0 : WAIT_TIMEOUT;
}

void LinuxReleaseSemaphore(wdsp_sem_t* sem,int release_count, int* previous_count) {
	pthread_mutex_lock(&sem->m);
	if (previous_count) *previous_count = (int)sem->count;
	sem->count += release_count;
	while (release_count-- > 0)
		pthread_cond_signal(&sem->c);
	pthread_mutex_unlock(&sem->m);
}

wdsp_sem_t *CreateEvent(void* security_attributes,int bManualReset,int bInitialState,char* name) {
	// auto-reset event == binary semaphore; WDSP never uses manual-reset semantics
	return LinuxCreateSemaphore(0, bInitialState ? 1 : 0, 1, 0);
}

void LinuxSetEvent(wdsp_sem_t* sem) {
	LinuxReleaseSemaphore(sem, 1, 0);
}

void LinuxResetEvent(wdsp_sem_t* sem) {
	// drain so the "event" reads as non-signaled
	pthread_mutex_lock(&sem->m);
	sem->count = 0;
	pthread_mutex_unlock(&sem->m);
}

unsigned int LinuxWaitForMultipleObjects(unsigned int count, void **handles, int waitAll, int ms) {
	// waitAll is not supported; WDSP only waits for "any" (calcc doPSCorrChange).
	// Poll each semaphore; on INFINITE, sleep 1 ms between sweeps.
	(void)waitAll;
	for (;;) {
		for (unsigned int i = 0; i < count; i++)
			if (LinuxWaitForSingleObject((wdsp_sem_t *)handles[i], 0) == WAIT_OBJECT_0)
				return WAIT_OBJECT_0 + i;
		if (ms != INFINITE) return WAIT_TIMEOUT;
		usleep(1000);
	}
}

HANDLE wdsp_beginthread( void( __cdecl *start_address )( void * ), unsigned stack_size, void *arglist) {
	pthread_t threadid;
	pthread_attr_t  attr;
	int rc = 0;

	if (rc = pthread_attr_init(&attr)) {
 	    return (HANDLE)-1;
	}
      
	if(stack_size!=0) {
	    if (rc = pthread_attr_setstacksize(&attr, stack_size)) {
	        return (HANDLE)-1;
	    }
	}

        if( rc = pthread_attr_setdetachstate(&attr,PTHREAD_CREATE_DETACHED)) {
            return (HANDLE)-1;
        }
     
	if (rc = pthread_create(&threadid, &attr, (void*(*)(void*))start_address, arglist)) {
	     return (HANDLE)-1;
	}

        //pthread_attr_destroy(&attr);
#ifndef __APPLE__
	// DL1YCF: this function does not exist on MacOS. You can only name the
        //         current thread.
        rc=pthread_setname_np(threadid, "WDSP");
#endif

	return (HANDLE)threadid;

}

void _endthread() {
	int res;
	pthread_exit((void *)&res);
}

void SetThreadPriority(HANDLE thread, int priority)  {
/*
	int policy;
	struct sched_param param;

	pthread_getschedparam(thread, &policy, &param);
	param.sched_priority = sched_get_priority_max(policy);
	pthread_setschedparam(thread, policy, &param);
*/
}

int CloseHandle(HANDLE hObject) {
//
// This routine is *ONLY* called to release semaphores/events
//
	wdsp_sem_t *sem = (wdsp_sem_t *)hObject;
	pthread_cond_destroy(&sem->c);
	pthread_mutex_destroy(&sem->m);
	free(sem);
// this is actually a void function (return value never used).
	return 0;
}

#endif
